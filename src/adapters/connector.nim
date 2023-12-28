import tunnel, strutils, store
import sequtils, chronos/transports/stream
import tunnels/transportident 
import tunnels/port 
# This module unfortunately has global shared memory as part of its state

logScope:
    topic = "Connectior Adapter"


#     1    2    3    4    5    6    7 ...
# ---------------------------------------------------
#                 User Requets
# ---------------------------------------------------
#     Connectior contains variable lenght data      |
# ---------------------------------------------------


type
    Protocol = enum
        Tcp,Udp
    ConnectorAdapter* = ref object of Adapter
        socket: StreamTransport
        readLoopFut: Future[void]
        writeLoopFut: Future[void]
        store: Store
        protocol:Protocol
        isMultiPort:bool
        targetIp:IpAddress
        targetPort:Port


const
    bufferSize = 4096


proc getRawSocket*(self: ConnectorAdapter): StreamTransport {.inline.} = self.socket

proc connect(self: ConnectorAdapter):Future[bool] {.async.}=
    assert self.socket == nil
    var (tident,_) = self.findByType(TransportIdentTunnel,right)
    doAssert tident != nil, "connector adapter could not locate TransportIdentTunnel! it is required"
    self.protocol =  if tident.isTcp : Tcp else: Udp

    if self.isMultiPort:
        var (port_tunnel,_) = self.findByType(PortTunnel,right)
        doAssert port_tunnel != nil, "connector adapter could not locate PortTunnel! it is required"
        self.targetPort = port_tunnel.getReadPort()
    if self.protocol == Tcp:
        var target = initTAddress(self.targetIp, self.targetPort)
        for i in 0 .. 4:
            try:
                var flags = {SocketFlags.TcpNoDelay, SocketFlags.ReuseAddr}
                self.socket = await connect(target, flags = flags)
                return true
            except CatchableError as e:
                error "could not connect TCP to the core! ", name = e.name, msg = e.msg
                if i != 4: notice "retrying ...", tries = i
                else: error "gauve up connecting to core", tries = i;return false
                

proc writeloop(self: ConnectorAdapter){.async.} =
    #read data from socket, write to chain
    var socket = self.socket
    var sv: StringView = nil
    while not self.stopped:
        try:
            sv = self.store.pop()
            sv.reserve(bufferSize)
            var actual = await socket.readOnce(sv.buf(), bufferSize)
            if actual == 0:
                trace "Writeloop read 0 !";
                self.store.reuse move sv
                if not self.stopped: signal(self, both, close)
                break
            else:
                trace "Writeloop read", bytes = actual
            sv.setLen(actual)

        except [CancelledError, TransportError]:
            var e = getCurrentException()
            trace "Writeloop Cancel, [Read]", msg = e.name
            if not self.stopped: signal(self, both, close)
            return
        except CatchableError as e:
            error "Writeloop Unexpected Error, [Read]", name = e.name, msg = e.msg
            quit(1)


        try:
            trace "Writeloop write", bytes = sv.len
            await procCall write(Tunnel(self), move sv)

        except [CancelledError, FlowError]:
            var e = getCurrentException()
            trace "Writeloop Cancel, [Write]", msg = e.name
            if not self.stopped: signal(self, both, close)
            return
        except CatchableError as e:
            error "Writeloop Unexpected Error, [Write]", name = e.name, msg = e.msg
            quit(1)



proc readloop(self: ConnectorAdapter){.async.} =
    #read data from chain, write to socket
    var socket = self.socket
    var sv: StringView = nil
    while not self.stopped:
        try:
            sv = await procCall read(Tunnel(self), 1)
            trace "Readloop Read", bytes = sv.len
        except [CancelledError, FlowError]:
            var e = getCurrentException()
            warn "Readloop Cancel, [Read]", msg = e.name
            if not self.stopped: signal(self, both, close)
            return
        except CatchableError as e:
            error "Readloop Unexpected Error, [Read]", name = e.name, msg = e.msg
            quit(1)


        if socket == nil:
            if await self.connect():
                self.writeLoopFut = self.writeloop()
                asyncSpawn self.writeLoopFut
            else:
                if not self.stopped: signal(self, both, close)
                return

        try:
            trace "Readloop write to socket", count = sv.len
            if sv.len != await socket.write(sv.buf, sv.len):
                raise newAsyncStreamIncompleteError()

        except [CancelledError, FlowError, TransportError, AsyncStreamError]:
            var e = getCurrentException()
            warn "Readloop Cancel, [Write]", msg = e.name
            if not self.stopped: signal(self, both, close)
            return
        except CatchableError as e:
            error "Readloop Unexpected Error, [Write]", name = e.name, msg = e.msg
            quit(1)
        finally:
            self.store.reuse move sv




method init(self: ConnectorAdapter, name: string, isMultiPort:bool,targetIp:IpAddress,targetPort:Port, store: Store){.raises: [].} =
    procCall init(Adapter(self), name, hsize = 0)
    self.store = store
    self.isMultiPort = isMultiPort
    self.targetIp = targetIp
    self.targetPort = targetPort



proc newConnectorAdapter*(name: string = "ConnectorAdapter",isMultiPort:bool,targetIp:IpAddress,targetPort:Port, store: Store): ConnectorAdapter {.raises: [].} =
    result = new ConnectorAdapter
    result.init(name, isMultiPort,targetIp,targetPort, store)
    trace "Initialized", name


method write*(self: ConnectorAdapter, rp: StringView, chain: Chains = default): Future[void] {.async.} =
    doAssert false, "you cannot call write of ConnectorAdapter!"

method read*(self: ConnectorAdapter, bytes: int, chain: Chains = default): Future[StringView] {.async.} =
    doAssert false, "you cannot call read of ConnectorAdapter!"


method start(self: ConnectorAdapter){.raises: [].} =
    {.cast(raises: []).}:
        procCall start(Adapter(self))
        trace "starting"

        self.readLoopFut = self.readloop()
        self.writeLoopFut = self.writeloop()
        asyncSpawn self.readLoopFut
        asyncSpawn self.writeLoopFut
            
proc stop*(self: ConnectorAdapter) =
    proc breakCycle(){.async.} =
        await sleepAsync(2000)
        self.signal(both,breakthrough)

    if not self.stopped:
        trace "stopping"
        self.stopped = true
        cancelSoon self.readLoopFut
        cancelSoon self.writeLoopFut
        self.socket.close()
        asyncSpawn breakCycle()

method signal*(self: ConnectorAdapter, dir: SigDirection, sig: Signals, chain: Chains = default){.raises: [].} =
    if sig == close or sig == stop: self.stop()

    if sig == breakthrough: doAssert self.stopped, "break through signal while still running?"

    procCall signal(Tunnel(self), dir, sig, chain)

    if sig == start: self.start()

