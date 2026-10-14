enum HLJSError: Error {
    case script(String)
    case contextIsNil
    case fileNotFound
    case hljsNotFound
    case valueNotFound
}
