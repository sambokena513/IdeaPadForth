Basic design:

    Security:
        Similarly to systems like TempleOS, we don't worry about security, but
        rather about extensibility and dynamism. As such, everything runs in ring 0
        and users are allowed to arbitrarily modify CPU state.
        Do note though that this is less an OS and more a bare-metal Forth, so
        nothing stops a user from deciding to implement a kernel in said Forth,
        deciding on an executable and filesystem formats, making the image entry point
        non-interactive, and loading code that runs in ring 3.
        As such, while security is not implemented here, it isn't impossible either.

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

        Subroutine threading:
            The bootstrap compiler only recognizes the LIT, 0BRANCH, BRANCH,
            and CALL IR instructions, emitting this code for each:

                LIT:
                    mov [ebp], imm32
                    add ebp, 8

                0BRANCH:
                    sub ebp, 8
                    cmp [ebp], 0
                    je rel32

                BRANCH:
                    jmp rel32

                CALL:
                    call [edi + 8*WORD_DESC + WD_IMPL]
                    (Note here, word descriptors have to be 8 bytes,
                     1 pointer for the impl and another for an extended
                     word struct, because otherwise we'd need more than
                     one instruction to perform this indirect call,
                     which'd rapidly inflate code size.)

        Calling Convention:
            Function arguments and return values go through the data stack,
            where ebp always points to the first free memory address above the NOS,
            and esi contains the cached TOS. This model makes passing
            arguments simple as well as allows the initial compiler to not
            worry about register allocation at all, while not forcing too many
            unnecessary memory accesses.

            In other words:

            esi = TOS
            ebp = &NOS + 4

            Note that the stack pointer points to the first *free* cell, so in
            an empty stack that's the first cell.

            Pushing a value to the stack is implemented as the following
            logical operation:

                mov [stack], tos
                mov tos, val
                add stack, cell_size

            And popping is:

                sub stack, cell_size
                mov tos, [stack]

            This means that a stack must be represented like:
                [invalid_memory, dummy_cell, cell1, cell2, ..., celln] in
                memory to guarantee correctness.
                In other words, caching the TOS costs us 4 bytes per stack.
            

    Parallelism/Concurrency:
        Not built-in, though the planned library-level implementation is
        cooperative multitasking similar to SmolForth for concurrency.

    Language semantics:
        See SmolForth at github.com/sambokena513/SmolForth, language semantics are
        the same as that save for the differences outlined in this document, as this
        is basically a spiritual successor to SmolForth; a Forth even smaller in the
        sense that it needs no OS to boot, it is the OS.

On-Disk Image Format:

    Persistent data structures:
        The image has 4 persistent data structures:
            - Dictionary: A word name to descriptor mapping.
            - Word descriptor table: Word entries that each correspond to a
              unique word identity.
            - Word implementation table: Implementation entries that each
              contain a 16-byte header with a reference count and size, and
              then machine code for the word.
            - Global variable & constant table: ALLOTed memory. Used by words
              like VARIABLE to allocate persistent memory, without this we'd
              need to make every global be in an impl, and thus make variables
              always work as indirect call to a word that pushes an address,
              with this though we can make them address with SIB normally.

    The image starts at LBA 128, its first sector
    contains an image header starting halway through the sector,
    then image entry point (byte offset), followed by disk block
    start:size pairs for each persistent data structure.
    Unless otherwise specified, assume fields are 64 bits.

    Pointers between the dictionary, word descriptor table, and word
    implementation table are initially image-start-relative in bytes.

Image Loading:

    The expected in-memory layout of an image is:

        - 0x7c00..0x8000 - Image header, contains 64-bit runtime pointers to start
                           locations for dictionary, word descriptor table,
                           and word implementation table, as well as all the
                           information that the on-disk header had.

        - [0x7c00]..[0x7c08] - Dictionary.
        - [0x7c10]..[0x7c16] - Word descriptor table.
        - [0x7c20]..[0x7c28] - Word implementation table.
        - [0x7c30]..[0x7c38] - Global variable & constant table.
        - [0x7c40]..[0x7c48] - Memory map.

    With this processor state:

        - edi = [0x7c10] (word desc table)
        - ebp = top of data stack
        - protected mode with flat segmentation and no paging
        - an initial main-context data and return stack, each being at least
          4KB large

    Therefore, an image loader must do at least these things:

        - Ensure the A20 line is enabled.
        - Get a memory map from BIOS.
        - Enter protected mode.
        - Read the sector at LBA 128 into 0x7c00, overwriting the MBR
          bootstrap code.
        - Put memory map start and size into the image header.
        - Parse the rest of the image header and based on that read different
          sector ranges into memory.
        - Allocate memory for, and put runtime pointers into image header for,
          all of the image's persistent data structures, and ensure edi gets
          the runtime pointer for the word descriptor table.
        - set up data and return stacks
        - Fix image-start-relative pointers for persistent data structures.
        - Jump to image entry point.
