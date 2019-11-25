import Foundation
import NIO

fileprivate func equal(lhs: StaticString, rhs: StaticString) -> Bool {
    if lhs.utf8CodeUnitCount != rhs.utf8CodeUnitCount {
        return false
    }
    
    return memcmp(lhs.utf8Start, rhs.utf8Start, lhs.utf8CodeUnitCount) == 0
}

struct ContextValueStore {
    let rootId: String
    let path: AnyKeyPath
    var subPaths: Set<AnyKeyPath>
}

public struct TemplateCompiler<Properties> {

    private var contexts = [ContextValueStore(rootId: "", path: \ContextValueStore.self, subPaths: [])]

    private var rootIdIndexes = [String: Int]()

    var buffer: ByteBuffer
    var keyPaths = [[AnyKeyPath]]()
    let stylesheet = StyleRegistery()
    
    init() {
        buffer = ByteBufferAllocator().buffer(capacity: 4_096)
    }

    private func index(for value: ContextValue) throws -> Int {
        let rootIndex = rootIdIndexes[value.rootId] ?? 0
        var pathIndex = 0
        for i in 0..<rootIndex {
            pathIndex += keyPaths[i].count
        }
        guard let subIndex = keyPaths[rootIndex].firstIndex(where: { $0 == value.keyPath }) else {
            throw TemplateError.internalCompilerError
        }
        return pathIndex + subIndex
    }
    
    private mutating func compileTemplateValue(_ value: TemplateValue) throws {
        switch value.storage {
        case .compileTime(let literal):
            buffer.writeInteger(CompiledTemplateValue.literal.rawValue)
            
            switch literal.storage {
            case .string(let string):
                compileString(string)
            }
        case .runtime(let path):
            buffer.writeInteger(CompiledTemplateValue.runtime.rawValue)
            buffer.writeInteger(try index(for: path), endianness: .little)
        }
    }
    
    private mutating func compile(_ modifier: _Modifier) throws {
        switch modifier {
        case .attribute(let name, let value):
            compileString(name)
            try compileTemplateValue(value)
        case .style(let type, let styles):
            compileString(type.rawValue)
            compileString(styles.map { $0.styleName }.joined(separator: " "))
            
            for style in styles {
                style.register?(self.stylesheet)
            }
        }
    }

    private mutating func compileKeyPaths() {
        keyPaths = [Array(contexts[0].subPaths)]
        let loopContextes = contexts.dropFirst()
        for context in loopContextes {
            if context.rootId.isEmpty {
                keyPaths[0].append(context.path)
            } else if let rootIndex = rootIdIndexes[context.rootId] {
                keyPaths[rootIndex].append(context.path)
            }
            keyPaths.append(Array(context.subPaths))
        }
    }
    
    private mutating func compileString(_ string: String) {
        buffer.writeInteger(UInt32(string.utf8.count), endianness: .little)
        buffer.writeString(string)
    }
    
    private mutating func compileString(_ string: StaticString) {
        buffer.writeInteger(UInt32(string.utf8CodeUnitCount), endianness: .little)
        buffer.writeStaticString(string)
    }
    
    private mutating func compile(_ node: TemplateNode) throws {

        switch node {
        case .none:
            buffer.writeInteger(CompiledNode.none.rawValue)
        case .tag(let name, let content, let modifiers):
            let data = Data(bytes: name.utf8Start, count: name.utf8CodeUnitCount)
            let name = String(data: data, encoding: .utf8)!
            
            buffer.writeInteger(CompiledNode.tag.rawValue)
            compileString(name)
            buffer.writeInteger(UInt8(modifiers.count))
            
            for modifier in modifiers {
                try compile(modifier)
            }
            
            try compile(content)
        case .literal(let literal):
            buffer.writeInteger(CompiledNode.literal.rawValue)
            compileString(literal)
        case .list(let nodes):
            buffer.writeInteger(CompiledNode.list.rawValue)
            buffer.writeInteger(UInt8(nodes.count))
            
            for node in nodes {
                try compile(node)
            }
        case .lazy(let render):
            try compile(render())
        case .contextValue(let path):
            buffer.writeInteger(CompiledNode.contextValue.rawValue)
            buffer.writeInteger(try index(for: path), endianness: .little)

        case .computedList(let path, let contextId, let node):
            buffer.writeInteger(CompiledNode.computedList.rawValue)
            guard let contextIndex = rootIdIndexes[contextId + "-loop-"] else {
                throw TemplateError.internalCompilerError
            }
            buffer.writeInteger(try index(for: path), endianness: .little)
            buffer.writeInteger(contextIndex, endianness: .little)
            try compile(node)
        case .contextIf(let condition, let content, _):
            buffer.writeInteger(CompiledNode.contextIfStart.rawValue)
            switch condition {
            case .equal(let lkp, let rkp):
                buffer.writeInteger(CompiledCondition.equal.rawValue)
                buffer.writeInteger(try index(for: lkp), endianness: .little)
                buffer.writeInteger(try index(for: rkp), endianness: .little)
            }
            try compile(content)
        }
    }
    
    public static func compile<T: Template>(_ type: T.Type) throws -> CompiledTemplate<Properties> {
        var compiler = TemplateCompiler()
        var node = TemplateNode(from: T())
        _ = compiler.optimize(&node)
        compiler.compileKeyPaths()
        try compiler.compile(node)
        return compiler.export()
    }
    
    public static func compile(_ root: Root) throws -> CompiledTemplate<Properties> {
        var compiler = TemplateCompiler()
        var node = root.node
        _ = compiler.optimize(&node)
        compiler.compileKeyPaths()
        try compiler.compile(node)
        return compiler.export()
    }
    
    private mutating func optimize(_ node: inout TemplateNode) -> Bool {
        switch node {
        case .none:
            return true
        case .list(let subnodes):
            var nodes = [TemplateNode]()
            var shouldReoptimize = false
            var result = ""
            
            func flushOptimization() {
                if result.isEmpty { return }
                
                nodes.append(.literal(result))
                result = ""
            }
            
            var iterator = subnodes.makeIterator()
            
            nextSubnode: while var subnode = iterator.next() {
                _ = optimize(&subnode)
                
                switch subnode {
                case .none:
                    continue nextSubnode
                case .list(let nestedList):
                    flushOptimization()
                    nodes.append(contentsOf: nestedList)
                    shouldReoptimize = true
                case .tag(let name, var content, let modifiers):

                    var modifierTemplate = modifiers.makeTemplateNode()

                    result += "<\(name)"
                    if case .literal(let literalModifierString) = modifierTemplate {
                        result += "\(literalModifierString)>"
                    } else {
                        flushOptimization()
                        _ = optimize(&modifierTemplate)
                        nodes.append(modifierTemplate)
                        result += ">"
                    }
                    
                    let isOptimized = optimize(&content)
                    if isOptimized, case .literal(let value) = content {
                        result += value
                    } else {
                        flushOptimization()
                        nodes.append(content)
                    }
                    
                    result += "</\(name)>"
                case .lazy(let build):
                    var resolved = build()
                    if !optimize(&resolved) {
                        shouldReoptimize = true
                    }
                    nodes.append(resolved)
                case .literal(let value):
                    result += value
                case .contextValue, .computedList, .contextIf:
//                    assert(!didOptimize, "Optimized node cannot be a contextValue, these are not optimizable")
                    flushOptimization()
                    nodes.append(subnode)
                }
            }
            
            flushOptimization()
            
            if nodes.count > 1 {
                if shouldReoptimize {
                    var optimizedNode = TemplateNode.list(nodes)
                    _ = optimize(&optimizedNode)
                    node = optimizedNode
                } else {
                    node = .list(nodes)
                }
            } else {
                node = nodes.first ?? .none
            }
            return true
        case .tag(let name, var content, let modifiers):

            var modifierTemplate = modifiers.makeTemplateNode()

            var start = "<\(name)"
            if case .literal(let literalModifierString) = modifierTemplate {
                start += "\(literalModifierString)>"
            } else {
                _ = optimize(&modifierTemplate)
                content = .list([
                    modifierTemplate,
                    .literal(">"),
                    content
                ])
            }
            let end = "</\(name)>"
            let isOptimized = optimize(&content)
            
            switch (isOptimized, content) {
            case (true, .literal(let value)):
                node = .literal(start + value + end)
            case (true, .none):
                node = .literal(start + end)
            case (true, .list):
                node = .list([
                    .literal(start),
                    content,
                    .literal(end)
                ])
            case (true, .computedList(let path, let contextId, let content)):
                node = .list([
                    .literal(start),
                    .computedList(path, contextId, content),
                    .literal(end)
                ])
            case (true, .contextValue(_)):
                node = .list([
                    .literal(start),
                    content,
                    .literal(end)
                ])
            case (true, _):
                fatalError("Invalid optimizer scenario, non-literal, non-empty and non-list optimized content")
            case (false, _):
                node = .list([
                    .literal(start),
                    content,
                    .literal(end)
                ])
            }
            
            return isOptimized
        case .lazy(let build):
            var resolved = build()
            let success = optimize(&resolved)
            node = resolved
            return success
        case .literal:
            return true
        case .computedList(let path, let contextId, var subNode):
            if rootIdIndexes[contextId + "-loop-"] == nil {
                rootIdIndexes[contextId + "-loop-"] = contexts.count
                contexts.append(ContextValueStore(rootId: path.rootId, path: path.keyPath, subPaths: []))
            }
            _ = optimize(&subNode)
            node = .computedList(path, contextId, subNode)
            return true
        case .contextValue(let path):
            if path.rootId.isEmpty {
                contexts[0].subPaths.insert(path.keyPath)
            } else if let index = rootIdIndexes[path.rootId] {
                contexts[index].subPaths.insert(path.keyPath)
            } else {
                fatalError()
            }
            return true
        case .contextIf(let lkp, let condition, let rkp):
            return false
        }
    }
    
    func export() -> CompiledTemplate<Properties> {
        let size = buffer.readableBytes
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        
        buffer.withUnsafeReadableBytes { buffer in
            _ = memcpy(pointer, buffer.baseAddress, size)
        }
        
        let buffer = UnsafeByteBuffer(pointer: pointer, size: size)
        return CompiledTemplate(template: buffer, keyPaths: keyPaths)
    }
}
