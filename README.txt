Basic design:

    Security:
        Similarly to systems like TempleOS, we don't worry about security, but
        rather about extensibility and dynamism. As such, everything runs in ring 0
        and users are allowed to arbitrarily modify CPU state.

    Dictionary:
        Rather than a traditional append-only linked list model, we have a
        multi-layer model, where the dictionary maps word names to word descriptors,
        and descriptors map word identities to implementations. A word descriptor
        contains a pointer to a code body, and generation number, as well as word
        flags.

        Important word flags are IMMEDIATE and STATIC currently, more may come
        later. STATIC marks a word descriptor as containing the same implementation
        for its whole lifetime, this lets the compiler inline functions.

        Dictionary mappings have a lifetime of until a word is unbound with
        FORGET, and word descriptors until a DELETE operation, word implementations
        have a short header with a reference count denoting the number of word
        descriptors referencing an implementation, their lifetime is until this hits
        0, and whether an impl should be freed is checked on every DELETE operation
        and REDEFINE operation.

        Code referencing an "xt" or "word identity" means a combination of word
        descriptor slot and generation, this lets word descriptor memory be reused by
        incrementing a generation counter (though we keep a high-water mark of the
        most words that were ever defined at once due to this unfortunately), and give
        us three composable operations with different semantics:

            define(codeptr) - get the first invalid word descriptor and increment its
                generation, or allocate and initialize a new one, and then set its
                implementation pointer to codeptr.

            delete(worddesc) - set the implementation pointer of worddesc to INVALID
                (a symbolic sentinel value, can be null or in a more complex environment a
                placeholder that throws an exception upon being called).

            patch(worddesc, codeptr) - set the implementation pointer of worddesc to
                codeptr without incrementing its generation, used to change word behaviour and
                make callers see the changes.

    Execution/Compilation model:
        This Forth has no inner interpreter, but rather word implementations
        execute native code. Compiler words (including the initial compiler) emit
        symbolic IR into a scratch arena, and then that gets run through an optimizer
        and code generator to finally emit optimized machine code into a word
        implementation. The nice thing about this is that the initial "compiler" and
        "IR" can be incredibly simple, just emitting subroutine-threaded code for
        example, while not preventing later optimizations.

    Parallelism/Concurrency:
        Not built-in, though the planned library-level implementations are
        cooperative multitasking similar to SmolForth for concurrency, and a DELEGATE
        word for making a function run a different CPU core, along with basic mutex
        wrappers in the stdlib.

    Language semantics:
        See SmolForth at github.com/sambokena513/SmolForth, language semantics are
        the same as that save for the differences outlined in this document, as this
        is basically a spiritual successor to SmolForth; a Forth even smaller in the
        sense that it needs no OS to boot, it is the OS.
