package main

import "core:fmt"
import "core:strings"
import "core:os"
import "core:log"

import "./0d/rt"
import interp "./0d/interpreter"

Datum :: union {
    Bang,
    Image,
}

Bang  :: struct {}
BANG  :: Bang{}
Image :: struct { /* []byte */ }

System    :: rt.System(Datum)
Connector :: rt.Connector(Datum)
Component :: rt.Component(Datum)
Handler   :: #type proc(^Component, rt.Port, Datum)

main :: proc() {
    context.logger = log.create_console_logger(
        lowest=.Debug,
        opt={.Level, .Time, .Terminal_Color},
    )

    sys: System

    // NOTE(z64): i haven't settled on a generalized registry implementation, so just doing the simplest thing here.
    // you can ignore this, it doesn't have anything to do with the example - just some bootstrapping.
    {
        registry := map[string]Handler {
            "bus"     = bus_idle,
            "display" = display,
            "R"       = r_idle,
        }

        decls, err := interp.parse_drawio_mxgraph("main.drawio")
        assert(err == nil, "Failed parsing diagram")

        for decl in decls {
            // HACK(z64): i don't yet have the interpreter handling IDs, etc. how i'd like, so this is just a bodge for this example program.
            // basically, it is just doing some fiddling so that element IDs can be used as indicies into sys.components.
            // please ignore it, it has nothing to do with this example :)
            {
                for &child in decl.children {
                    child.id <<= 4
                }

                for &con in decl.connections {
                    con.source.id <<= 4
                    con.target.id <<= 4
                }

                instance_idx := 0
                for &child in decl.children {
                    handler_proc := registry[child.name]
                    rt.add_component(&sys, child.name, handler_proc)
                    for &con in decl.connections {
                        switch con.dir {
                        case .Down:
                            if child.id == con.target.id do con.target.id = instance_idx
                        case .Across:
                            if child.id == con.source.id do con.source.id = instance_idx
                            if child.id == con.target.id do con.target.id = instance_idx
                        case .Up:
                            if child.id == con.source.id do con.source.id = instance_idx
                        case .Through:
                        }
                    }
                    child.id = instance_idx
                    instance_idx += 1
                }
            }

            for con in decl.connections {
                connector: Connector
                switch con.dir {
                case .Down:
                    connector = Connector {
                        src      = nil,
                        src_port = rt.Port(con.source_port),
                        dst      = sys.components[con.target.id],
                        dst_port = rt.Port(con.target_port),
                    }
                case .Up:
                case .Across:
                    connector = Connector {
                        src      = sys.components[con.source.id],
                        src_port = rt.Port(con.source_port),
                        dst      = sys.components[con.target.id],
                        dst_port = rt.Port(con.target_port),
                    }
                case .Through:
                }

                rt.add_connection(&sys, connector)
            }
        }
    }

    // this component effectively stubs out user input & some kind of frame event loop,
    // i.e. SDL poll, ....
    ex := rt.add_component(&sys, "extern", extern)

    // for the sake of this example, rewire all "down" connectors as coming from `ex`
    for &con in sys.connectors  {
        if con.src == nil {
            con.src = ex
        }
    }

    // top level connection into the system
    rt.add_connection(&sys, Connector {
        src      = nil,
        src_port = "poll",
        dst      = ex,
        dst_port = "poll",
    })

    // loopback
    rt.add_connection(&sys, Connector {
        src      = ex,
        src_port = "poll",
        dst      = ex,
        dst_port = "poll",
    })

    rt.run(&sys, "poll", BANG)
}

// NOTE(z64): instead of using time, i'm using a global frame counter, so that
// the simulation can be run step-by-step
frame_counter: int

extern :: proc(eh: ^Component, port: rt.Port, datum: Datum) {
    switch port {
    case "poll":
        buf: [256]byte

        fmt.printf("F=%d [b|f] > ", frame_counter)

        input_len, _ := os.read(os.stdin, buf[:])
        input: string

        switch input_len {
        case 0:
            input = ""
        case 1:
            input = "f"
        case:
            input = transmute(string)(buf[:input_len-1])
        }

        poll := true

        switch input {
        case "b":
            rt.send(eh, "button", BANG)
        case "f":
            // just send frame pulse
        case:
            poll = false
        }

        rt.send(eh, "frame", BANG)
        frame_counter += 1

        if poll {
            rt.send(eh, "poll", BANG)
        }
    }
}

// ----------------------------------------------------------------------------- LEAVES

// ------------------------------------------------------------------ BUS

// How many frame to check for an image result
CHECK_FRAME_INTERVAL :: 5

Bus :: struct {
    image:       Maybe(Image),
    check_frame: int,
}

bus_idle :: proc(eh: ^Component, port: rt.Port, datum: Datum) {
    data := (^Bus)(eh.data)
    switch port {
    case rt.ENTER:
        if eh.data == nil {
            eh.data = new(Bus)
        }
    case "button":
        rt.tran(eh, bus_wait)
    case "frame":
        // ... do something on every frame while idle ...
    }
}

bus_wait :: proc(eh: ^Component, port: rt.Port, datum: Datum) {
    data := (^Bus)(eh.data)
    switch port {
    case rt.ENTER:
        rt.send(eh, "query", BANG)
    case "button":
        // ignore button while loading
    case "frame":
        idle_frames := frame_counter - data.check_frame
        if idle_frames > CHECK_FRAME_INTERVAL {
            data.check_frame = frame_counter
            rt.send(eh, "check", BANG)
        }
    case "image":
        image := datum.(Image)
        data.image = image
        rt.send(eh, "image", image)
        rt.tran(eh, bus_idle)
    }
}

// ------------------------------------------------------------------ DISPLAY

display :: proc(eh: ^Component, port: rt.Port, datum: Datum) {
    @(static) frame_buffer: string
    switch port {
    case rt.ENTER:
        frame_buffer = "[.....]"
    case "draw":
        image := datum.(Image)
        frame_buffer = "[IMAGE]"
    case "present":
        fmt.println(frame_buffer)
    case "clear":
        frame_buffer = "[.....]"
    }
}

// ------------------------------------------------------------------ R

// How many frames it takes to produce an image
R_LATENCY_FRAMES :: 7

R :: struct {
    image_delivery_frame: int,
}

r_idle :: proc(eh: ^Component, port: rt.Port, datum: Datum) {
    data := (^R)(eh.data)
    switch port {
    case rt.ENTER:
        if eh.data == nil {
            eh.data = new(R)
        }
    case "query":
        rt.tran(eh, r_processing)
    }
}

r_processing :: proc(eh: ^Component, port: rt.Port, datum: Datum) {
    data := (^R)(eh.data)
    switch port {
    case rt.ENTER:
        data.image_delivery_frame = frame_counter + R_LATENCY_FRAMES
    case "check":
        if frame_counter >= data.image_delivery_frame {
            rt.send(eh, "image", Image{})
            rt.tran(eh, r_idle)
        }
    }
}
