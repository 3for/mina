package main

import (
	cryptorand "crypto/rand"
	"time"

	"codanet"

	capnp "capnproto.org/go/capnp/v3"
	"github.com/go-errors/errors"
	crypto "github.com/libp2p/go-libp2p-core/crypto"
	net "github.com/libp2p/go-libp2p-core/network"
	peer "github.com/libp2p/go-libp2p-core/peer"
	peerstore "github.com/libp2p/go-libp2p-core/peerstore"
	discovery "github.com/libp2p/go-libp2p-discovery"
	pubsub "github.com/libp2p/go-libp2p-pubsub"
	"github.com/multiformats/go-multiaddr"
	ipc "libp2p_ipc"
)

func (app *app) handleBeginAdvertising(seqno uint64, m ipc.Libp2pHelperInterface_BeginAdvertising_Request) *capnp.Message {
	if app.P2p == nil {
		return mkRpcRespError(seqno, needsConfigure())
	}

	for _, info := range app.AddedPeers {
		app.P2p.Logger.Debug("Trying to connect to: ", info)
		err := app.P2p.Host.Connect(app.Ctx, info)
		if err != nil {
			app.P2p.Logger.Error("failed to connect to peer: ", info, err.Error())
			continue
		}
	}

	foundPeerCh := make(chan peerDiscovery)

	validPeer := func(who peer.ID) bool {
		return who.Validate() == nil && who != app.P2p.Me
	}

	// report discovery peers local and remote
	go func() {
		for discovery := range foundPeerCh {
			if validPeer(discovery.info.ID) {
				app.P2p.Logger.Debugf("discovered peer %v via %v; processing", discovery.info.ID, discovery.source)
				app.P2p.Host.Peerstore().AddAddrs(discovery.info.ID, discovery.info.Addrs, peerstore.ConnectedAddrTTL)

				if discovery.source == PEER_DISCOVERY_SOURCE_MDNS {
					for _, addr := range discovery.info.Addrs {
						app.P2p.GatingState.MarkPrivateAddrAsKnown(addr)
					}
				}

				// now connect to the peer we discovered
				connInfo := app.P2p.ConnectionManager.GetInfo()
				if connInfo.ConnCount < connInfo.LowWater {
					err := app.P2p.Host.Connect(app.Ctx, discovery.info)
					if err != nil {
						app.P2p.Logger.Error("failed to connect to peer after discovering it: ", discovery.info, err.Error())
						continue
					}
				}
			} else {
				app.P2p.Logger.Debugf("discovered peer %v via %v; not processing as it is not a valid peer", discovery.info.ID, discovery.source)
			}
		}
	}()

	if !app.NoMDNS {
		app.P2p.Logger.Infof("beginning mDNS discovery")
		err := beginMDNS(app, foundPeerCh)
		if err != nil {
			app.P2p.Logger.Error("failed to connect to begin mdns: ", err.Error())
			return mkRpcRespError(seqno, badp2p(err))
		}
	}

	if !app.NoDHT {
		app.P2p.Logger.Infof("beginning DHT discovery")
		routingDiscovery := discovery.NewRoutingDiscovery(app.P2p.Dht)
		if routingDiscovery == nil {
			err := errors.New("failed to create routing discovery")
			return mkRpcRespError(seqno, err)
		}

		app.P2p.Discovery = routingDiscovery

		err := app.P2p.Dht.Bootstrap(app.Ctx)
		if err != nil {
			app.P2p.Logger.Error("failed to dht bootstrap: ", err.Error())
			return mkRpcRespError(seqno, badp2p(err))
		}

		time.Sleep(time.Millisecond * 100)
		app.P2p.Logger.Debugf("beginning DHT advertising")

		_, err = routingDiscovery.Advertise(app.Ctx, app.P2p.Rendezvous)
		if err != nil {
			app.P2p.Logger.Error("failed to routing advertise: ", err.Error())
			return mkRpcRespError(seqno, badp2p(err))
		}

		go func() {
			peerCh, err := routingDiscovery.FindPeers(app.Ctx, app.P2p.Rendezvous)
			if err != nil {
				app.P2p.Logger.Error("error while trying to find some peers: ", err.Error())
			}

			for peer := range peerCh {
				foundPeerCh <- peerDiscovery{
					info:   peer,
					source: PEER_DISCOVERY_SOURCE_ROUTING,
				}
			}
		}()
	}

	app.P2p.ConnectionManager.OnConnect = func(net net.Network, c net.Conn) {
		app.updateConnectionMetrics()

		id := c.RemotePeer()

		app.writeMsg(mkPeerDisconnectedUpcall(peer.Encode(id)))
	}

	app.P2p.ConnectionManager.OnDisconnect = func(net net.Network, c net.Conn) {
		app.updateConnectionMetrics()

		id := c.RemotePeer()

		app.writeMsg(mkPeerConnectedUpcall(peer.Encode(id)))
	}

	return mkRpcRespSuccess(seqno, func(m *ipc.Libp2pHelperInterface_RpcResponseSuccess) {
		_, err := m.NewBeginAdvertising()
		panicOnErr(err)
	})
}

func (app *app) handleConfigure(seqno uint64, msg ipc.Libp2pHelperInterface_Configure_Request) *capnp.Message {
	m, err := msg.Config()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	app.UnsafeNoTrustIP = m.UnsafeNoTrustIp()
	listenOnMaList, err := m.ListenOn()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	listenOn := make([]multiaddr.Multiaddr, 0, listenOnMaList.Len())
	err = multiaddrListForeach(listenOnMaList, func(v string) error {
		res, err := multiaddr.NewMultiaddr(v)
		if err == nil {
			listenOn = append(listenOn, res)
		}
		return err
	})
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	seedPeersMaList, err := m.SeedPeers()
	seeds := make([]peer.AddrInfo, 0, seedPeersMaList.Len())
	err = multiaddrListForeach(seedPeersMaList, func(v string) error {
		addr, err := addrInfoOfString(v)
		if err == nil {
			seeds = append(seeds, *addr)
		}
		return err
	})
	// TODO: this isn't necessarily an RPC error. Perhaps the encoded multiaddr
	// isn't supported by this version of libp2p.
	// But more likely, it is an RPC error.
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	app.AddedPeers = append(app.AddedPeers, seeds...)

	directPeersMaList, err := m.DirectPeers()
	directPeers := make([]peer.AddrInfo, 0, directPeersMaList.Len())
	err = multiaddrListForeach(directPeersMaList, func(v string) error {
		addr, err := addrInfoOfString(v)
		if err == nil {
			directPeers = append(directPeers, *addr)
		}
		return err
	})
	// TODO: this isn't necessarily an RPC error. Perhaps the encoded multiaddr
	// isn't supported by this version of libp2p.
	// But more likely, it is an RPC error.
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	externalMa, err := m.ExternalMultiaddr()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	externalMaRepr, err := externalMa.Representation()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	externalMaddr, err := multiaddr.NewMultiaddr(externalMaRepr)
	if err != nil {
		return mkRpcRespError(seqno, badAddr(err))
	}

	gc, err := m.GatingConfig()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	gatingConfig, err := readGatingConfig(gc, app.AddedPeers)
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	stateDir, err := m.Statedir()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	netId, err := m.NetworkId()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	privkBytes, err := m.PrivateKey()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	privk, err := crypto.UnmarshalPrivateKey(privkBytes)
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	helper, err := codanet.MakeHelper(app.Ctx, listenOn, externalMaddr, stateDir, privk, netId, seeds, gatingConfig, int(m.MaxConnections()), m.MinaPeerExchange())
	if err != nil {
		return mkRpcRespError(seqno, badHelper(err))
	}

	// SOMEDAY:
	// - stop putting block content on the mesh.
	// - bigger than 32MiB block size?
	opts := []pubsub.Option{pubsub.WithMaxMessageSize(1024 * 1024 * 32),
		pubsub.WithPeerExchange(m.PeerExchange()),
		pubsub.WithFloodPublish(m.Flood()),
		pubsub.WithDirectPeers(directPeers),
		pubsub.WithValidateQueueSize(int(m.ValidationQueueSize())),
	}

	var ps *pubsub.PubSub
	ps, err = pubsub.NewGossipSub(app.Ctx, helper.Host, opts...)
	if err != nil {
		return mkRpcRespError(seqno, badHelper(err))
	}

	helper.Pubsub = ps
	app.P2p = helper

	app.P2p.Logger.Infof("here are the seeds: %v", seeds)

	metricsServer := app.metricsServer
	if metricsServer != nil && metricsServer.port != m.MetricsPort() {
		metricsServer.Shutdown()
	}
	if m.MetricsPort() > 0 {
		metricsServer = startMetricsServer(m.MetricsPort())
		if !app.metricsCollectionStarted {
			go app.checkBandwidth()
			go app.checkPeerCount()
			go app.checkMessageStats()
			go app.checkLatency()
			app.metricsCollectionStarted = true
		}
	}

	return mkRpcRespSuccess(seqno, func(m *ipc.Libp2pHelperInterface_RpcResponseSuccess) {
		_, err := m.NewConfigure()
		panicOnErr(err)
	})
}

func (app *app) handleGetListeningAddrs(seqno uint64, m ipc.Libp2pHelperInterface_GetListeningAddrs_Request) *capnp.Message {
	if app.P2p == nil {
		return mkRpcRespError(seqno, needsConfigure())
	}
	addrs := app.P2p.Host.Addrs()
	return mkRpcRespSuccess(seqno, func(m *ipc.Libp2pHelperInterface_RpcResponseSuccess) {
		r, err := m.NewGetListeningAddrs()
		panicOnErr(err)
		lst, err := r.NewResult(int32(len(addrs)))
		panicOnErr(err)
		setMultiaddrList(lst, addrs)
	})
}

func (app *app) handleGenerateKeypair(seqno uint64, m ipc.Libp2pHelperInterface_GenerateKeypair_Request) *capnp.Message {
	privk, pubk, err := crypto.GenerateEd25519Key(cryptorand.Reader)
	if err != nil {
		return mkRpcRespError(seqno, badp2p(err))
	}
	privkBytes, err := crypto.MarshalPrivateKey(privk)
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	pubkBytes, err := crypto.MarshalPublicKey(pubk)
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	peerID, err := peer.IDFromPublicKey(pubk)
	if err != nil {
		return mkRpcRespError(seqno, badp2p(err))
	}

	return mkRpcRespSuccess(seqno, func(m *ipc.Libp2pHelperInterface_RpcResponseSuccess) {
		resp, err := m.NewGenerateKeypair()
		panicOnErr(err)
		res, err := resp.NewResult()
		panicOnErr(err)
		panicOnErr(res.SetPrivateKey(privkBytes))
		panicOnErr(res.SetPublicKey(pubkBytes))
		pid, err := res.NewPeerId()
		panicOnErr(pid.SetId(peer.Encode(peerID)))
	})
}

func (app *app) handleListen(seqno uint64, m ipc.Libp2pHelperInterface_Listen_Request) *capnp.Message {
	if app.P2p == nil {
		return mkRpcRespError(seqno, needsConfigure())
	}
	iface, err := m.Iface()
	if err != nil {
		return mkRpcRespError(seqno, badp2p(err))
	}
	ma, err := multiaddr.NewMultiaddr(iface)
	if err != nil {
		return mkRpcRespError(seqno, badp2p(err))
	}
	if err := app.P2p.Host.Network().Listen(ma); err != nil {
		return mkRpcRespError(seqno, badp2p(err))
	}
	addrs := app.P2p.Host.Addrs()
	return mkRpcRespSuccess(seqno, func(m *ipc.Libp2pHelperInterface_RpcResponseSuccess) {
		r, err := m.NewListen()
		panicOnErr(err)
		lst, err := r.NewResult(int32(len(addrs)))
		panicOnErr(err)
		setMultiaddrList(lst, addrs)
	})
}

func (app *app) handleSetGatingConfig(seqno uint64, m ipc.Libp2pHelperInterface_SetGatingConfig_Request) *capnp.Message {
	if app.P2p == nil {
		return mkRpcRespError(seqno, needsConfigure())
	}
	gc, err := m.GatingConfig()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	newState, err := readGatingConfig(gc, app.AddedPeers)
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}

	app.P2p.GatingState = newState

	return mkRpcRespSuccess(seqno, func(m *ipc.Libp2pHelperInterface_RpcResponseSuccess) {
		_, err := m.NewSetGatingConfig()
		panicOnErr(err)
	})
}

func (app *app) handleSetNodeStatus(seqno uint64, m ipc.Libp2pHelperInterface_SetNodeStatus_Request) *capnp.Message {
	status, err := m.Status()
	if err != nil {
		return mkRpcRespError(seqno, badRPC(err))
	}
	app.P2p.NodeStatus = status
	return mkRpcRespSuccess(seqno, func(m *ipc.Libp2pHelperInterface_RpcResponseSuccess) {
		_, err := m.NewSetNodeStatus()
		panicOnErr(err)
	})
}