package rt

import "core:log"
import "core:container/queue"

Message :: struct($User_Datum: typeid) {
    port:  Port,
    datum: User_Datum,
}

Port :: distinct string

System :: struct($User_Datum: typeid) {
    components: [dynamic]^Component(User_Datum),
    connectors: [dynamic]Connector(User_Datum),
}

Connector :: struct($User_Datum: typeid) {
    src:      ^Component(User_Datum),
    src_port: Port,
    dst:      ^Component(User_Datum),
    dst_port: Port,
}

FIFO      :: distinct queue.Queue(Message)
fifo_push :: queue.push_back
fifo_pop  :: queue.pop_front_safe

Component :: struct($User_Datum: typeid) {
    name:    string,
    input:   queue.Queue(Message(User_Datum)),
    output:  queue.Queue(Message(User_Datum)),
    handler: #type proc(component: ^Component(User_Datum), port: Port, data: User_Datum),
    data:    rawptr,
}

step :: proc(sys: ^System($User_Datum)) -> (retry: bool) {
    for component in sys.components {
        for component.output.len > 0 {
            msg, _ := fifo_pop(&component.output)
            log.debugf("[OUT  ] %s/%s", component.name, msg.port)
            route(sys, component, msg)
        }
    }

    for component in sys.components {
        msg, ok := fifo_pop(&component.input)
        if ok {
            log.debugf("[IN   ] %s/%s", component.name, msg.port)
            component.handler(component, msg.port, msg.datum)
            retry = true
        }
    }
    return retry
}

route :: proc(sys: ^System($User_Datum), from: ^Component(User_Datum), msg: Message(User_Datum)) {
    for c in sys.connectors {
        if c.src == from && c.src_port == msg.port {
            new_msg := msg
            new_msg.port = c.dst_port
            fifo_push(&c.dst.input, new_msg)
        }
    }
}

add_component :: proc(sys: ^System($User_Datum), name: string, handler: proc(^Component(User_Datum), Port, User_Datum)) -> ^Component(User_Datum) {
    component := new(Component(User_Datum))
    component.name = name
    component.handler = handler
    append(&sys.components, component)
    return component
}

add_connection :: proc(sys: ^System($User_Datum), connection: Connector(User_Datum)) {
    append(&sys.connectors, connection)
}

send :: proc(component: ^Component($User_Datum), port: Port, data: User_Datum) {
    fifo_push(&component.output, Message(User_Datum){port, data})
}

ENTER :: Port("__STATE_ENTER__")
EXIT  :: Port("__STATE_EXIT__")

tran :: proc(component: ^Component($User_Datum), state: proc(^Component(User_Datum), Port, User_Datum)) {
    log.debugf("[STATE] %s: %v -> %v", component.name, component.handler, state)
    component.handler(component, EXIT, nil)
    component.handler = state
    component.handler(component, ENTER, nil)
}

run :: proc(sys: ^System($User_Datum), port: Port, data: User_Datum) {
    msg := Message(User_Datum){port, data}
    route(sys, nil, msg)

    for component in sys.components {
        log.debugf("[STATE] %s -> ENTER", component.name)
        component.handler(component, ENTER, nil)
    }

    for step(sys) {
        // ...
    }

    for component in sys.components {
        log.debugf("[STATE] %s -> EXIT", component.name)
        component.handler(component, EXIT, nil)
    }
}
