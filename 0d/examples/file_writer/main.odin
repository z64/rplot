package demo

import "core:os"
import "core:slice"
import "core:log"
import "core:fmt"

import  rt "../../rt"

// Set of datum types that this program works with.
Datum :: union {
    Bang,
    string,
    []byte,
    os.Errno,
}

// Zero-sized type used to just kick something off.
Bang :: struct{}
BANG :: Bang{}

// Imports for brevity.
System         :: rt.System(Datum)
Component      :: rt.Component(Datum)
Connector      :: rt.Connector(Datum)
add_component  :: rt.add_component
add_connection :: rt.add_connection
run            :: rt.run
Port           :: rt.Port
send           :: rt.send
tran           :: rt.tran
ENTER          :: rt.ENTER
EXIT           :: rt.EXIT

open_file_for_writing :: proc(path: string) -> (os.Handle, os.Errno) {
    return os.open(path, os.O_CREATE | os.O_WRONLY | os.O_TRUNC, 0o644)
}

File_Writer_State :: struct {
    path:   string,
    handle: os.Handle,
}

// Initial file writer state.
file_writer_init :: proc(eh: ^Component, port: Port, datum: Datum) {
    state := (^File_Writer_State)(eh.data)

    switch port {
    case ENTER:
        eh.data = new(File_Writer_State)
    case "open":
        path := datum.(string)
        handle, err := open_file_for_writing(path)
        if err == os.ERROR_NONE {
            state.path = path
            state.handle = handle
            send(eh, "open", BANG)
            tran(eh, file_writer_write)
        } else {
            send(eh, "error", err)
        }
    }
}

// File opened for writing.
file_writer_write :: proc(eh: ^Component, port: Port, datum: Datum) {
    state := (^File_Writer_State)(eh.data)

    switch port {
    case "write":
        bytes := datum.([]byte)
        _, err := os.write(state.handle, bytes)
        if err == os.ERROR_NONE {
            send(eh, "ok", BANG)
        } else {
            send(eh, "error", err)
        }
    case EXIT:
        os.close(state.handle)
        free(eh.data)
    }
}

// Reads from stdin.
terminal_input_reader :: proc(eh: ^Component, port: Port, datum: Datum) {
    BUFFER_SIZE :: 1024
    read_buffer := slice.from_ptr((^u8)(eh.data), BUFFER_SIZE)

    switch port {
    case ENTER:
        read_buffer = make([]u8, BUFFER_SIZE)
        eh.data = raw_data(read_buffer)
    case "read":
        fmt.print("> ")
        len, _ := os.read(os.stdin, read_buffer)
        if len == 1 && read_buffer[0] == '\n' {
            send(eh, "empty", BANG)
        } else {
            send(eh, "line", read_buffer[:len])
        }
    case EXIT:
        delete(read_buffer)
    }
}

// Logs errors.
error_logger :: proc(eh: ^Component, port: Port, datum: Datum) {
    switch port {
    case ENTER, EXIT:
        // ignore
    case:
        log.errorf("%s: %v", port, datum)
    }
}

main :: proc() {
    context.logger = log.create_console_logger(
        lowest=.Debug,
        opt={.Level, .Time, .Terminal_Color},
    )

    sys: System

    file_writer    := add_component(&sys, "file_writer", file_writer_init)
    terminal_input := add_component(&sys, "terminal_input", terminal_input_reader)
    error_logger   := add_component(&sys, "error_logger", error_logger)

    // Start the network by opening the file.
    add_connection(&sys, Connector{
        nil, "input",
        file_writer, "open",
    })

    // Once the file is open, read a line.
    add_connection(&sys, Connector{
        file_writer, "open",
        terminal_input, "read",
    })

    // When a line is produced, write it to the file.
    add_connection(&sys, Connector{
        terminal_input, "line",
        file_writer, "write",
    })

    // If the write succeeded, read another line.
    add_connection(&sys, Connector{
        file_writer, "ok",
        terminal_input, "read",
    })

    // Error routing.
    add_connection(&sys, Connector{
        file_writer, "error",
        error_logger, "file writer",
    })

    file := slice.get(os.args, 1) or_else "demo.txt"

    fmt.println("Writing to", file)
    fmt.println("Enter empty line to exit.")

    run(&sys, "input", file)
}
