@_exported import OpenAttributeGraphShims

// without the env var the shims build OpenAttributeGraph's own engine, which is still a stub
let backendIsAttributeGraph = attributeGraphVendor == .ag
