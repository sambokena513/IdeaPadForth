Language design:

    Security:
        Similarly to systems like TempleOS, we don't worry about security, but
        rather about extensibility and dynamism. As such, everything runs in ring 0
        and users are allowed to arbitrarily modify CPU state.
        Do note though that this is less an OS and more a bare-metal Forth, so
        nothing stops a user from deciding to implement a kernel in said Forth,
        deciding on an executable and filesystem formats, making the image entry point
        non-interactive, and loading code that runs in ring 3.
        As such, while security is not implemented here or planned, it isn't impossible either.

    Dictionary:
        Rather than a traditional append-only linked list model, we have a
        multi-layer model, where the dictionary maps word names to word descriptors,
        and descriptors map word identities to implementations. A word descriptor
        contains a pointer to a code body, and generation number, as well as word
        flags.

        Important word flags are IMMEDIATE and STATIC currently, more may come
        later. STATIC marks a word descriptor as containing the same implementation
        for its whole lifetime, this lets the compiler inline functions.

        Note that STATIC only means the descriptor-impl association is static,
        not that the implementation will always be loaded at the same address,
        so any calls not inlined still need to go through the descriptor to
        get the correct address.

        Dictionary mappings have a lifetime of until a word is unbound with
        FORGET, and word descriptors until a DELETE operation, word implementations
        have a short header with a reference count denoting the number of word
        descriptors referencing an implementation, their lifetime is until this hits
        0, and whether an impl should be freed is checked on every DELETE operation
        and PATCH operation.

        Code referencing an "xt" or "word identity" means a combination of word
        descriptor slot and generation, this lets word descriptor memory be reused by
        incrementing a generation counter (though we keep a high-water mark of the
        most words that were ever defined at once due to this unfortunately), and gives
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

        Dictionary Entry Struct:

            typedef struct DictEntry {
                uint32 next; // may be NULL, in which case there is no next entry
                uint32 wd_idx; // where to find the associated word
                uint32 wd_gen; // if there's a mismatch between this and the
                               // generation field of the WordDesc at wd_idx
                               // then words like EXECUTE will throw exceptions
                uint32 name_len; // length-prefixed strings
                char[] name; // external name to FIND words by
            } DictEntry;

        Word Descriptor Struct:

            typedef struct WordDesc {
                *void impl; // this is a direct pointer to machine code,
                               subtracting sizeof(WordImplDesc) from this will give you the WordImpl
                uint32 generation;
                uint32 flags;
            } WordDesc;

        Word Implementation Struct:

            typedef struct WordImplDesc {
                uint32 refcount; // number of references to this impl
                uint32 code_len; // length of machine code in bytes
                IR[] ir; // used by other words for inlining if they reference this impl
                            through a STATIC word descriptor
                uint32 ir_len; // length of IR array in bytes
            }

            typedef struct WordImpl {
                WordImplDesc properties;
                char[] code; // note that pointers to WordImpl's are actually
                             // pointers to this code array, not to the WordImplDesc
                             // that is higher in the struct
            } WordImpl;

    Execution/Compilation model:
        This Forth has no inner interpreter, but rather word implementations
        execute native code. Compiler words (including the initial compiler) emit
        symbolic IR into a scratch arena, and then that gets run through an optimizer
        and code generator to finally emit optimized machine code into a word
        implementation. The nice thing about this is that the initial "compiler" and
        "IR" can be incredibly simple, just emitting subroutine-threaded code for
        example, while not preventing later optimizations.

        The symbolic IR that serves as the interface between compiler words
        and the code-generator/optimizer is an array of simple instruction
        struct pointers, each instruction has a type and operands, the initial
        instructions that must be implemented by the IR format are LIT(imm32),
        0BRANCH(offset), BRANCH(offset), CALL(worddesc), Note that though x86 makes jumps utilize a
        32-bit *displacement* rather than absolute addresses, in our symbolic IR
        branches target offsets from the start of the word (indices into the IR array).

        Subroutine threading:
            The bootstrap compiler only recognizes the LIT, 0BRANCH, BRANCH,
            and CALL IR instructions, emitting this code for each:

                LIT:
                    mov [ebp], imm32
                    add ebp, 4

                0BRANCH:
                    sub ebp, 4
                    cmp [ebp], 0
                    je rel32

                BRANCH:
                    jmp rel32

                CALL:
                    call [edi + WORD_DESC_SIZE*WORD_DESC]
                         (note that since this is a constant calculation,
                          the actual encoding is edi + disp32)

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
            an empty stack that's the first cell, also the stack grows upward.

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

                An empty stack is represented by ebp pointing to the dummy
                cell and esi being undefined, normal nonempty stacks of length
                N have ebp pointing to index N.

            Argument order:
                The top of the stack is always considered the first argument
                to a function, and subsequent args are given in lower stack
                postitions. A concrete example would be `1 2 -`, this will
                evaluate to +1, not -1.

            Caller/Callee-saved Registers and Reserved Registers:
                caller-saved - eax, ebx, ecx, edx
                callee-saved - none

                reserved - esi (TOS), edi (WD_TABLE start), ebp (&NOS + 4), esp (return stack)

                Rationale:
                    Function arguments go through the stack anyway so overhead
                    would be relatively high regardless of how we split up the
                    registers, and if we split them evenly we only get 2
                    registers for use in leaf functions.

                    By giving all four to leaf node functions we can make
                    primitives noticeably faster (as well as some non-primitives
                    if we do inlining), and lose almost nothing.

    Parallelism/Concurrency:
        Not a built-in language feature, though the planned library-level
        implementation is cooperative multitasking similar to SmolForth's <stdco.f>
        library, only with a fair virtual-runtime based scheduler using a red-black
        tree to represent the runnable set rather than round-robin with a linked list.

        No parallelism or synchronization because this system is designed to
        run on single-core processors and does not make use of features like
        hyperthreading either, and synchronization is not an issue since code
        runs in ring 0 with the ability to mask interrupts for critical sections.

        Also, it's important to note that concurrency interacts with word
        implementation lifetime, if a word is redefined with PATCH while one
        or more execution contexts contain it somewhere along the call chain,
        then it cannot be freed yet, thus when concurrency is implemented then
        the DELETE or PATCH operations will need to cooperate with the
        scheduler and temporarily make each task that references it boost the
        refcount, as well as insert a callback that will decrement the
        refcount and possibly free the impl.

        This is pretty slow, but well, that's what you get when trying
        to change hot code in a running system. Remember, our target is
        not extremely performant hot code reload, its good performance
        normally when the system is not being changed, and the *ability*
        to change it at runtime if you wish, and do so without recompiling
        everything.

    Language semantics:
        See SmolForth at github.com/sambokena513/SmolForth, language semantics are
        the same as that save for the differences outlined in this document, as this
        is basically a spiritual successor to SmolForth; a Forth even smaller in the
        sense that it needs no OS to boot, it is the OS.

On-Disk Image Format - Revision 1:

    Persistent data structures:
        The image currently has 4 persistent data structures, though this list
        may be expanded in the future:
            - Dictionary: A word name to descriptor mapping.
            - Word descriptor table: Word entries that each correspond to a
              unique word identity.
            - Word implementation table: Implementation entries that each
              contain an header with a reference count and size, and
              then machine code for the word.
            - Global variable & constant table: ALLOTed memory. Used by words
              like VARIABLE to allocate persistent memory, without this we'd
              need to make every global be in an impl, and thus make variables
              always work as indirect call to a word that pushes an address,
              with this though we can make them address with SIB normally.

    The image starts at LBA 64, its first sector
    contains an image header starting halway through the sector,
    consisting of image entry point (word descriptor idx), number of persistent data
    structures, followed by disk block start:size pairs for each persistent data structure.
    Unless otherwise specified, assume fields are 32 bits.

    Note that because the image header contains LBA start fields and sector
    counts, in principle the logical image can actually be spread across the
    disk, only individual persistent data structures need to be contiguous,
    this is useful because if the image being loaded implements a filesystem
    of some sort, you can make each data structure be a file, and put the
    filesystem's root metadata at LBA 65 (right after the image header).

    To detect corrupted and/or unbootable images, the first half of the image
    header sector contains a small descriptor of the image header in this
    format which bootloaders may choose to ignore, but can be used to verify the
    image is correct:

        typedef struct IHeaderDesc {
            // note that the crc32sum here is calculated
            // from just the 256-byte image header, not the whole
            // 512-byte sector containing it and the IHeaderDesc
            char[8] magic = "FIF IMG ";
            uint32 revision;
            uint32 crc32sum; // more specifically CRC-32/ISO-HDLC
        }

    Persistent Data Structure format:

        // note, sectors here and lba assume 512-byte sectors,
        // on disks with larger logical blocks the bootloader
        // might need to do some left shifts on this to know
        // how many sectors to actually read
        typedef struct PData {
            uint32 start_lba;
            uint32 sector_count;
        } PData;

    Image Header format:

        typedef struct IHeader {
            uint32 image_entry; // the word descriptor the bootloader should call
            uint32 pdata_entry_count; // number of PData structs in this header
            PData[] data;
        } IHeaderDesc;

    Pointers between the dictionary, word descriptor table, and word
    implementation table are initially section-start-relative in bytes.

    Finally, the order of persistent data structures matters, a persistent
    data structure's index will be the same in the on-disk header and in memory
    once loaded, so for referencing data structure roots you need the index to be
    stable, apart from that indices 0, and 1 have special meanings.

    Index 0 - Word descriptor table, a pointer to the start of this data
    structure can be expected to be in edi when the image is entered.

    Index 1 - Word implementation table.

Image Loading:

    The expected in-memory layout of an image is:

        - 0x7c00..0x8000 - Image header, contains 32-bit runtime pointers to start
                           locations for dictionary, word descriptor table,
                           and word implementation table, as well as all the
                           information that the on-disk header had.

        - [0x7c00]..[0x7c04] - Memory map.
        - [0x7c08]..[0x7c0c] - Word descriptor table.
        - [0x7c10]..[0x7c14] - Word implementation table.
        - [0x7c18]..[0x7c1c] - Dictionary.
        - [0x7c20]..[0x7c24] - Global variable & constant table.
        - ... - other persistent data structures.

        Persistent data structure in-memory format:

            typedef struct PDataLoaded {
                *char start;
                *char end;
            }

    With this processor state:

        - edi = [0x7c08] (word desc table)
        - ebp = data stack pointer (&NOS + 4)
        - protected mode with flat segmentation and no paging
        - an initial main-context data and return stack, each being at least
          4KB large

    Additionally, references between the word descriptor table and word
    implementation table must be resolved into runtime pointers by the
    bootloader. Remaining persistent data structures will be initialized by
    the forth image. This is to make it easy to expand the image with new
    data structures, while still making sure a minimal execution environment
    exists once the entry point is reached, and to make sure the bootloader
    doesn't have to initialize *too* much.

    Therefore, an image loader must do at least these things:

        - Ensure the A20 line is enabled.
        - Get a memory map from BIOS.
        - Enter protected mode.
        - Read the sector at LBA 64 into 0x7c00, overwriting the MBR
          bootstrap code.
        - Put memory map start and size into the image header.
        - Parse the rest of the image header and based on that read different
          sector ranges into memory.
        - Allocate memory for, and put runtime pointers into image header for,
          all of the image's persistent data structures, and ensure edi gets
          the runtime pointer for the word descriptor table.
        - Fix section-start-relative pointers for word desc table and word impl
          table.
        - set up data and return stacks
        - Jump to image entry point.

OS Architecture (so far, this section is subject to change):

    Execution:

        The system is essentially an embedded-style superloop at the moment, there
        are hardcoded "tasks" in a bitmap which can have pending work or be suspended, tasks
        and ISRs can set these bits, and the superloop checks the bits to invoke the
        corresponding function. The bitmap is represented as a 32-bit machine
        integer, if the integer is 0 we know there is no work, and can halt the CPU.

    Subsystems:

        Interrupts - We currently use the 8259 PIC to handle interrupts, on
        top of the normal IDT to maintain our expected late-binding Forth
        semantics we have an "IDeT" or Interrupt Descriptor Extension Table,
        this maps interrupt vectors to word descriptors letting us invoke the
        right handler even if is is redefined.

        Memory management - At the moment you cannot free memory, we have a
        small kernel arena (64KB) initialized once at bootup that drivers can allocate
        from on initialization for their data structures, such as various ring
        buffers. The planned physical memory manager is a free stack of pages
        + a buddy allocator, and perhaps a slower specialized allocator for getting
        memory suitable for ISA device drivers.

        Drivers - Currently drivers are not dynamically loaded and neither are
        devices dynamically discovered, we simply have
        a few tasks in our bitmap for background stuff, we have a PS/2 keyboard, VGA
        text console and very basic terminal driver, these are in the process of being
        reworked to provide a cleaner interface that doesn't depend on the specific
        console implementation.

        Planned architecture for the input and display subsystem:

            Layer 0 - Drivers: the keyboard and mouse drivers generate input events
                and send them to a configured primary input receiver, also known as the "input
                router"

            Layer 1 - IO Router: the IO Router manages both window compositing, as
                well as which application is "focused", and which virtual screen is
                visible. It handles the alt+<number> shortcut for switching virtual
                terminals, and the super+<number> shortcut for switching viewports.

            Layer 2 - Consoles: A virtual console presents a clean logical character-cell
                rendering interface for terminals or other applications to use for
                displaying things, consoles are implemented by keeping track of a few
                important pieces of state inside an array of x * y length, this array
                contains character cell descriptor structs of the format:

                    - bit 31 - a flag for if this character cell is dirty
                    - bits 30..16 - a 15-bit offset from 0xb8000 of the physical
                      character cell this logical character cell describes
                    - bits 15..0  - current glyph and attribute byte of character cell

                Additionally, a console also needs to provide this struct for
                applications and the compositor to be able to use it:

                    struct {
                        // required by terminals
                        uint32 render_glyph;
                        uint32 query_size;
                        uint32 cls;

                        // these are required for the compositor
                        uint32 displayed;
                        uint32 cell_buf;
                        uint16 line_count;
                        uint16 line_length
                    }

                When a console is being displayed (the `displayed` field is set to
                -1), rendering operations should update the stored glyph and
                attribute, but also follow the VGA mapping to display memory and
                actually display the character, when it is not displayed, then it
                should still write to its internal buffer, but instead of displaying,
                it should set the `dirty` bit for character cells it touches, the
                compositor will display these when the console is eventually displayed again.

                Application-facing API:

                    console_render_glyph(uint32 console, uint32 x, uint32 y, uint8 glyph, uint8 attributes)
                        - render an ASCII glyph on <console> at <x,y>, if <glyph>
                          is not a printable ASCII character, behaviour is undefined.
                          Returns 0 on success or -1 on failure (such as invalid
                          coordinates or if it's backed by a graphics driver, graphics
                          problem). Finally, the <attributes> argument determines the
                          background and foreground color of the displayed glyph,
                          this is a VGA attribute byte, even if the console is not a
                          VGA text console, it must accept VGA-style attribute bytes
                          for colors.

                    console_query_size(uint32 console)
                        - obtain the range of valid x and y coordinates for a given
                          console.

                    console_cls(uint32 console)
                        - clear the screen, equivalent to calling render_glyph() on
                          on every character cell with ASCII 32 as the glyph, but more
                          performant. Same as render_glyph(), returns error code.


            Layer 3 - Terminals: virtual terminals are backed by consoles, and provide
                a familiar command-line-like interface for most applications, of
                course an application can also directly mark *itself* as being the "terminal"
                and then simply choose not to implement terminal functionality, but instead
                directly manage its console (such as graphical text-mode applications that
                want to make use of the mouse and widgets)

                Application-facing API:

                    term_putc(uint32 character)
                        - print a character to the screen

                    term_puts(uint32 string)
                        - print a string to the screen

                    term_getc()
                        - get a character from terminal input, returning an 8-bit
                          ASCII value, if no characters are available, return 0

                    term_scroll(uint8 direction)
                        - Scroll one line upwards or downwards, depending on terminal
                          implementation may or may not re-display text that
                          previously scrolled off the screen, direction should be 0
                          for scrolling upwards, or -1 for scrolling downwards.
                          If the terminal does not implement scrollback, or the user
                          scrolled too far and the text is no longer in memory, fill
                          the removed line with ASCII 32 characters.

                    term_reset()
                        - reset cursor position, attributes, clear the screen,
                          and clear buffers

                    term_get_attr()
                        - returns a 32-bit bitmap where each bit corresponds to
                          whether one setting is enabled or disabled.
                          current settings are bit 0 = XLATE, bit 1 = ECHO,
                          and bit 2 = RAW. Additionally, the latter 16 bit half of the
                          attributes is not a bitmap, but rather contains the colors
                          (represented as VGA attribute bytes) for normal and
                          highlighted text respectively.

                    term_set_attr(uint32 attr)
                        - write an attribute bitmap back to the terminal

                    term_set_term(uint32 terminal)
                        - set which terminal the above operations should operate on,
                          as all of them implicitly operate on the idea of a "current
                          terminal", this operation however is not itself part *of*
                          the terminal, but rather global or per-task state.

                    XLATE - When this setting is enabled, nonprintable characters
                            in putc and puts will be translated into longer sequences
                            to provide expected behaviour. For instance, \b becomes
                            \b, space, \b. And \n becomes \r\n, this also affects
                            echoed characters from the keyboard.

                    ECHO - When this setting is enabled, characters received from the
                           keyboard are printed before making them available to the
                           application, when it is disabled, typing produces no
                           visible output automatically.

                    RAW - When this setting is enabled, all characters go directly to
                          the application immediately, and control characters coming
                          from the keyboard are not processed (such as DEL), when it
                          is *disabled*, then characters are buffered into a line sepa
                          rately from the application-visible input buffer, and
                          certain keys producing control characters (such as backspace
                          producing DEL) are interpreted by the terminal emulator for
                          line and screen editing instead of being sent to the
                          application.

                    Note that all of these functions are called indirectly through a
                    terminal struct, this struct must contain *at least* these fields
                    and in this order:

                        struct {
                            uint32 putc;
                            uint32 puts;
                            uint32 getc;
                            uint32 scroll;
                            uint32 reset;
                            uint32 get_attr;
                            uint32 set_attr;
                        }

                    However each implementation is free to add its own extra fields
                    for internal state.
