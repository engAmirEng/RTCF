import chronos, chronos/transports/[datagram, ipnet], chronos/osdefs
import adapters/[ws, connection, mux, connector]
import tunnel, tunnels/[port, tcp, udp, transportident]
import store, shared ,httputils
import websock/[websock, extensions/compression/deflate]

from globals import nil

logScope:
    topic = "Iran RightSide"

var foundpeer = false

proc handle(request: HttpRequest) {.async.} =
    trace "Handling request:", uri = request.uri.path
    var address = request.stream.writer.tsource.remoteAddress()

    if  request.uri.path != "/ws" & $globals.sh1:
        request.stream.close()
        warn "rejected websocket connection, password mismatch!"
        return
        
    if not foundpeer:
        foundpeer = true
        lock(peerConnectedlock):
            peerConnected = true

    try:
        let deflateFactory = deflateFactory()
        let server = WSServer.new(factories = [deflateFactory])
        let ws = await server.handleRequest(request)
        if ws.readyState != Open:
            error "Failed to open websocket connection"
            return

        # trace "Websocket handshake completed"
        trace "Got Websocket connection", form = address

        var mux_adapter = newMuxAdapetr(master = masterChannel, store = publicStore, loc = BeforeGfw)
        var ws_adapter = newWebsocketAdapter(socket = ws, store = publicStore)
        mux_adapter.chain(ws_adapter)
        mux_adapter.signal(both, start)



    except WebSocketError as e:
        error "Websocket error", name = e.name, msg = e.msg



proc startWebsocketServer(threadID: int) {.async.} =
    {.cast(gcsafe).}:
        var socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr,ServerFlags.ReusePort}
        if globals.keep_system_limit:
            socketFlags.excl ServerFlags.TcpNoDelay

        
        var server = 
            # HttpServer.create(initTAddress("127.0.0.1:8888"), flags = socketFlags) 
            TlsHttpServer.create(
                address = initTAddress(globals.listen_addr,globals.cf_listen_port),
                tlsPrivateKey = TLSPrivateKey.init(globals.pkey),
                tlsCertificate = TLSCertificate.init(globals.cert),
                flags = socketFlags)
       

        proc accepts() {.async, raises: [Defect].} =
            while true:
                try:
                    let req = await server.accept()
                    await req.handle()
                except CatchableError as e:
                    error "Https Accept error", name = e.name, msg = e.msg

        asyncCheck accepts()
      

        trace "Started Ws Server", internalPort = globals.cf_listen_port
        await server.join()


proc run*(thread: int) {.async.} =
    await sleepAsync(200)
    # if globals.accept_udp:
    #     info "Mode Iran (Tcp + Udp)"
    # else:
    #     info "Mode Iran"
    dynamicLogScope(thread):
        await startWebsocketServer(thread)

