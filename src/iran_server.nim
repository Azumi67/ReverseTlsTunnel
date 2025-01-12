import std/[strformat, strutils, random, endians]
import chronos
import chronos/osdefs
import times, print, connection, pipe
from globals import nil

type
    TunnelConnectionPoolContext = object
        # listener_server: Connection # for testing on local pc
        listener: StreamServer
        user_inbounds: Connections
        peer_inbounds: Connections
        peer_ip: IpAddress


var context = TunnelConnectionPoolContext()
var mux = false

proc monitorData(data: var string): bool =
    try:
        let base = 5 + 7 + `mod`(globals.sh5, 7.uint8)
        if data.high.uint8 < base + 4: return false
        var sh1_c: uint32
        var sh2_c: uint32

        copyMem(addr sh1_c, addr data[base+0], 4)
        copyMem(addr sh2_c, addr data[base+4], 4)

        let chk1 = sh1_c == globals.sh1
        let chk2 = sh2_c == globals.sh2

        if (chk1 and chk2):

            return true
        else:
            return false

    except:
        return false

proc generateFinishHandShakeData(client_port: Port): string =
    let rlen: uint16 = uint16(16*(6+rand(4)))
    var port = client_port.uint32
    var random_trust_data: string
    random_trust_data.setLen(rlen)

    copyMem(addr random_trust_data[0], addr(globals.random_str[rand(250)]), rlen)
    copyMem(addr random_trust_data[0], addr globals.tls13_record_layer[0], 3) #tls header
    copyMem(addr random_trust_data[3], addr rlen, 2) #tls len

    let base = 5 + 7 + `mod`(globals.sh5, 7.uint8)
    copyMem(addr random_trust_data[base+0], addr globals.sh3.uint32, 4)
    copyMem(addr random_trust_data[base+4], addr globals.sh4.uint32, 4)
    if globals.multi_port:
        copyMem(addr random_trust_data[base+8], addr client_port, 4)

    return random_trust_data


proc acquireRemoteConnection():Future[Connection] {.async.} =
    var remote:Connection = nil
    if mux:
        discard
        # for i in 0..<400:
        #     remote = context.peer_inbounds.randomPick()
        #     if remote != nil:
        #         if remote.mux_holds.len().uint32 >= remote.mux_capacity:
        #             context.peer_inbounds.remove(remote) # old connection
        #             continue
        #         remote.mux_holds.add client.id
        #         break
        #     await sleepAsync(10)
    else:
        for i in 0..<400:
            remote = context.peer_inbounds.grab()
            if remote != nil:
                if remote.closed: continue
                break
            await sleepAsync(10)
    return remote

proc connectTargetSNI(): Future[Connection] {.async.} =
    let address = initTAddress(globals.final_target_ip, globals.final_target_port)
    var new_remote: Connection = await connection.connect(address)
    new_remote.trusted = TrustStatus.no
    if globals.log_conn_create: echo "connected to ", globals.final_target_domain, ":", $globals.final_target_port
    return new_remote

proc processConnection(client: Connection) {.async.} =
    var processRemoteFuture: Future[void]

    proc closeLine(remote,client:Connection) {.async.} =
        if globals.log_conn_destory: echo "closed client & remote"
        if remote != nil:
            await allFutures(remote.closeWait(), client.closeWait())
        else:
            await client.closeWait()


    proc processRemote(remote: Connection) {.async.} =

        var data = newString(len = 0)
        var boundary: uint16 = 0

        try:
            while not remote.isNil and not remote.closed:
                #read
                data.setlen remote.reader.tsource.offset
                if data.len() == 0:
                    if remote.reader.atEof():
                        await closeLine(client,remote)
                        return
                    else:
                        discard await remote.reader.readOnce(addr data, 0)
                        continue
                if remote.isTrusted:
                    if boundary == 0:
                        let width = globals.full_tls_record_len.int
                        data.setLen width
                        await remote.reader.readExactly(addr data[0], width)
                        copyMem(addr boundary, addr data[3], sizeof(boundary))
                        if boundary == 0: break
                        continue
                    let readable = min(boundary, data.len().uint16)
                    boundary -= readable; data.setlen readable
                    await remote.reader.readExactly(addr data[0], readable.int)
                else:
                    await remote.reader.readExactly(addr data[0], data.len)
                if globals.log_data_len: echo &"[processRemote] {data.len()} bytes from remote"


                # write
                if mux:
                    if remote.isTrusted:
                        let (cid, port) = unPackForReadMux(data)
                        echo &"[processRemote] {data.len()} bytes from mux remote"
                        if data.len() == 0: #mux client close
                            echo "Wanted to close: ", cid
                        context.user_inbounds.with(cid, name = con):
                            if data.len() == 0: #mux client close
                                echo "[processRemote] closed Mux client"
                                await con.closeWait()
                                context.user_inbounds.remove cid
                                remote.mux_holds.remove cid
                                inc remote.mux_closes
                            else:
                                if not con.closed:
                                    await con.writer.write(data)
                                    if globals.log_data_len: echo &"[processRemote] {data.len} bytes -> Mux client "
                    else:
                        if not client.closed:
                            await client.writer.write(data)
                            if globals.log_data_len: echo &"[processRemote] {data.len} bytes -> client "
                else:
                    if remote.isTrusted:
                        unPackForRead(data)
                    if not client.closed:
                        await client.writer.write(data)
                        if globals.log_data_len: echo &"[processRemote] {data.len} bytes -> client "


        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()

        #close
        if mux:
            for cid in remote.mux_holds:
                context.user_inbounds.with(cid, name = con):
                    await con.closeWait()
                context.user_inbounds.remove(cid)
                echo "[1] removed user_inbound: ", cid
        else:
            if remote.isTrusted:
                await client.closeWait()
            if not remote.isNil(): await remote.closeWait()



    proc processClient(remote: Connection) {.async.} =
        var data = newString(len = 0)
        try:
            while not client.closed:
                #read
                data.setlen client.reader.tsource.offset
                if data.len() == 0:
                    if client.reader.atEof():
                        break
                    else:
                        discard await client.reader.readOnce(addr data, 0)
                        continue
                if globals.log_data_len: echo &"[processClient] {data.len()} bytes from client {client.id}"
                if client.trusted == TrustStatus.no:
                    let width = globals.full_tls_record_len.int
                    data.setLen(data.len() + width)
                    await client.reader.readExactly(addr data[0 + width], data.len - width)
                else:
                    await client.reader.readExactly(addr data[0], data.len)



                #trust based route
                if client.trusted == TrustStatus.pending:
                    var trust = monitorData(data)
                    if trust:
                        #peer connection
                        client.trusted = TrustStatus.yes
                        let address = client.transp.remoteAddress()
                        print "Peer Fake Handshake Complete ! ", address
                        if mux: context.user_inbounds.remove(client)
                        context.peer_inbounds.register(client)
                        context.peer_ip = client.transp.remoteAddress.address
                        await remote.closeWait() # close untrusted remote
                        # await processRemoteFuture
                        if mux:
                            discard
                            # remote = client
                            # remote.setBuffered()
                            # asyncCheck processRemote(client)
                        if not globals.multi_port and not client.closed:
                            await client.writer.write(generateFinishHandShakeData(client.port))
                        return
                    else:
                            if (epochTime().uint - client.creation_time) > globals.trust_time:
                                #user connection but no peer connected yet
                                #peer connection but couldnt finish handshake in time
                                client.trusted = TrustStatus.no
                                if mux:
                                    await closeLine(client,remote)
                                    return
                                else:
                                    break

                #write             
                if not remote.closed:
                    if remote.isTrusted:
                        if mux: packForSendMux(client.id, client.port.uint16, data) else: packForSend(data)
                    await remote.writer.write(data)
                    if globals.log_data_len: echo &"{data.len} bytes -> Remote"
                else:
                    break

        except:
            if globals.log_conn_error: echo getCurrentExceptionMsg()

        #close
        if mux:
            await client.closeWait()
            context.user_inbounds.remove(client)
            if not remote.closed and remote.mux_holds.contains(client.id):
                var data = ""
                packForSendMux(client.id, client.port.uint16, data)
                await remote.writer.write(data)
            if remote.mux_holds.contains(client.id):
                remote.mux_holds.remove client.id
                inc remote.mux_closes
            if remote.mux_closes >= remote.mux_capacity:
                await closeLine(client,remote) #end full connection
        else:
            await closeLine(client,remote)


    #Initialize remote
    try:
        var remote: Connection = nil
        if globals.trusted_foreign_peers.len != 0 and
            client.transp.remoteAddress.address in globals.trusted_foreign_peers:
            #load balancer connection
            remote = await connectTargetSNI()

        elif context.peer_ip != IpAddress() and
            context.peer_ip != client.transp.remoteAddress.address:
            echo "Real User connected !"
            client.trusted = TrustStatus.no
            remote = await acquireRemoteConnection() #associate peer
            if remote != nil:
                if mux: context.user_inbounds.register(client)
                if globals.log_conn_create: echo &"[createNewCon][Succ] Associated a peer connection"
                if globals.multi_port:
                    await remote.writer.write(generateFinishHandShakeData(client.port))

            else:
                if globals.log_conn_destory: echo &"[createNewCon][Error] left without connection, closes forcefully."
                await client.closeWait()
                return
        else:
            remote = await connectTargetSNI()

        if not mux: asyncCheck processRemote(remote) # mux already called this
        asyncCheck processClient(remote)

    except:
        printEx()

proc start*(){.async.} =
    var pbuf = newString(len = 16)

    proc start_listener(){.async.} =

        proc serveStreamClient(server: StreamServer,
                        transp: StreamTransport) {.async.} =
            try:
                let con = await Connection.new(transp)
                let address = con.transp.remoteAddress()
                if globals.multi_port:
                    var origin_port: int
                    var size = 16
                    if not getSockOpt(transp.fd, int(globals.SOL_IP), int(globals.SO_ORIGINAL_DST),
                    addr pbuf[0], size):
                        echo "multiport failure getting origin port. !"
                        await con.closeWait()
                        return
                    bigEndian16(addr origin_port, addr pbuf[2])

                    con.port = origin_port.Port

                    if globals.log_conn_create: print "Connected client: ", address, con.port
                else:
                    con.port = server.local.port.Port
                    if globals.log_conn_create: print "Connected client: ", address

                asyncCheck processConnection(con)
            except:
                echo "handle client connection error:"
                echo getCurrentExceptionMsg()




        var address = initTAddress(globals.listen_addr, globals.listen_port.Port)

        let server: StreamServer =
            try:
                createStreamServer(address, serveStreamClient, {ReuseAddr})
            except TransportOsError as exc:
                raise exc
            except CatchableError as exc:
                raise exc
        context.listener = server

        if globals.multi_port:
            assert globals.listen_port == server.localAddress().port
            # globals.listen_port = server.localAddress().port # its must be same as listen port

            globals.createIptablesForwardRules()

        server.start()
        echo &"Started tcp server... {globals.listen_addr}:{globals.listen_port}"



    mux = globals.mux
    trackIdleConnections(context.peer_inbounds,globals.pool_age)

    await sleepAsync(200)
    echo &"Mode Iran : {globals.self_ip}  handshake: {globals.final_target_domain}"
    asyncCheck start_listener()
    # asyncCheck start_server_listener()





