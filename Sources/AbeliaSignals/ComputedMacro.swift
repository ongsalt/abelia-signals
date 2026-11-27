@attached(body)
@attached(peer, names: prefixed(_$))
public macro Computed() = #externalMacro(
    module: "AbeliaSignalsMacros",
    type: "ComputedMacro"
)

@attached(body)
@attached(peer, names: prefixed(_$))
public macro Computed<T>(equals: (T, T) -> Bool) = #externalMacro(
    module: "AbeliaSignalsMacros",
    type: "ComputedMacro"
)

@attached(body)
@attached(peer, names: prefixed(_$))
public macro Computed(equals: Never?) = #externalMacro(
    module: "AbeliaSignalsMacros",
    type: "ComputedMacro"
)
