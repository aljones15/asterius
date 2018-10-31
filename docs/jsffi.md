## JavaScript FFI

There is a prototype implementation of `foreign import javascript` right now, check the `jsffi` test suite for details. The syntax is like:

```
foreign import javascript "new Date()" current_time :: IO JSRef

foreign import javascript "console.log(${1})" js_print :: JSRef -> IO ()
```

The source text of `foreign import javascript` should be a valid JavaScript expression (but you can use something like `${1}`, `${2}` to refer to the function parameters). Supported basic types are:

* `Ptr`
* `FunPtr`
* `StablePtr`
* `Bool`
* `Int`
* `Word`
* `Char`
* `Float`
* `Double`
* `JSRef`

The result can be wrapped in `IO` (or not).

`JSRef` is a magic type that doesn't actually appear in any module's source code. In the Haskell land, `JSRef` is first-class and opaque: you can pass it around, put it in a data structure, etc, but under the hood it's just a handle. The runtime maintains mappings from handles to real JavaScript objects.

Note that it's currently impossible to properly define `newtype`s to `JSRef` and use them in JSFFI import/export declarations. The asterius compiler rewrites all `JSRef` to `Int` at parse time, which doesn't play well with the ordinary FFI type checking mechanism. We need to stay with type synonyms at the moment.

Also, a prototype of `foreign export javascript` is implemented, check `jsffi` for details. The syntax is roughly:

```
foreign export javascript "mult_hs" (*) :: Int -> Int -> Int
```

In a Haskell module, one can specify the exported function name (must be globally unique), along with its Haskell identifier and type. One can specify `ahc-link --export-function=mult_hs` to make the linker include the relevant bits in final WebAssembly binary, and export `mult_hs` as a regular WebAssembly export function. After calling `hs_init` to initialize the runtime, one can call `mult_hs` just like a regular JavaScript function.

### Adding a JSFFI basic type

Look at the following places:

* `Asterius.JSFFI` module. All JavaScript reference types are uniformly handled as `FFI_JSREF`, while value types are treated as `FFI_VAL`. Assuming we are adding a value type. Add logic to:
    * `marshalToFFIValueType`: Recognize the value type in parsed AST, and translate to `FFI_VAL`
* `Asterius.Builtins` module. Add the corresponding `rts_mkXX`/`rts_getXX` builtin functions. They are required for stub functions of `foreign export javascript`.

### Implementation

This subsection presents a high-level overview on the implementation of JSFFI, based on the information flow from syntactic sugar to generated WebAssembly/JavaScript code.

#### Syntactic sugar

As documented in previous sections, one can write `foreign import javascript` or `foreign export javascript` clauses in a `.hs` module. How are they processed? The logic resides in `Asterius.JSFFI`.

First, there is `addFFIProcessor`, which given a `Compiler` (defined in `ghc-toolkit`), returns a new `Compiler` and a callback to fetch a stub module. The details of `Compiler`'s implementation are not relevant here, just think of it as an abstraction layer to fetch/modify GHC IRs without dealing with all the details of GHC API.

`addFFIProcessor` adds one functionality to the input `Compiler`: rewrite parsed Haskell AST and handle the `foreign import javascript`/`foreign export javascript` syntactic sugar. After rewriting, JavaScript FFI is really turned into C FFI, so type-checking/code generation proceeds as normal.

After the parsed AST is processed, a "stub module" of type `AsteriusModule` is generated and can be later fetched given an `AsteriusModuleSymbol`. It contains JSFFI related information of type `FFIMarshalState`. Both `AsteriusModule` and `FFIMarshalState` types has `Semigroup` instance so they can be combined later at link-time.

#### TODO
