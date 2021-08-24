package main

import (
	gonet "net"
	"time"

	"codanet"

	capnp "capnproto.org/go/capnp/v3"
	"github.com/go-errors/errors"
	peer "github.com/libp2p/go-libp2p-core/peer"
	ma "github.com/multiformats/go-multiaddr"
	ipc "libp2p_ipc"
)

type codaPeerInfo struct {
	Libp2pPort uint16
	Host       string
	PeerID     string
}

func filterIPString(filters *ma.Filters, ip string, action ma.Action) error {
	realIP := gonet.ParseIP(ip).To4()

	if realIP == nil {
		// TODO: how to compute mask for IPv6?
		return errors.New("unparsable IP or IPv6")
	}

	ipnet := gonet.IPNet{Mask: gonet.IPv4Mask(255, 255, 255, 255), IP: realIP}

	filters.AddFilter(ipnet, action)

	return nil
}

func readMultiaddrList(l ipc.Multiaddr_List) ([]string, error) {
	res := make([]string, 0, l.Len())
	return res, multiaddrListForeach(l, func(v string) error {
		res = append(res, v)
		return nil
	})
}

func multiaddrListForeach(l ipc.Multiaddr_List, f func(string) error) error {
	for i := 0; i < l.Len(); i++ {
		el, err := l.At(i).Representation()
		if err != nil {
			return err
		}
		err = f(el)
		if err != nil {
			return err
		}
	}
	return nil
}

func capnpPeerIdListForeach(l ipc.PeerId_List, f func(string) error) error {
	for i := 0; i < l.Len(); i++ {
		el, err := l.At(i).Id()
		if err != nil {
			return err
		}
		err = f(el)
		if err != nil {
			return err
		}
	}
	return nil
}

func capnpTextListForeach(l capnp.TextList, f func(string) error) error {
	for i := 0; i < l.Len(); i++ {
		el, err := l.At(i)
		if err != nil {
			return err
		}
		err = f(el)
		if err != nil {
			return err
		}
	}
	return nil
}

func readGatingConfig(gc ipc.GatingConfig, addedPeers []peer.AddrInfo) (*codanet.CodaGatingState, error) {
	_, totalIpNet, err := gonet.ParseCIDR("0.0.0.0/0")
	if err != nil {
		return nil, err
	}

	// TODO: perhaps the isolate option should just be passed down to the gating state instead
	bannedAddrFilters := ma.NewFilters()
	if gc.Isolate() {
		bannedAddrFilters.AddFilter(*totalIpNet, ma.ActionDeny)
	}

	bannedIps, err := gc.BannedIps()
	if err != nil {
		return nil, err
	}
	err = capnpTextListForeach(bannedIps, func(ip string) error {
		return filterIPString(bannedAddrFilters, ip, ma.ActionDeny)
	})
	if err != nil {
		return nil, err
	}

	trustedAddrFilters := ma.NewFilters()
	trustedAddrFilters.AddFilter(*totalIpNet, ma.ActionDeny)

	trustedIps, err := gc.TrustedIps()
	if err != nil {
		return nil, err
	}
	err = capnpTextListForeach(trustedIps, func(ip string) error {
		return filterIPString(trustedAddrFilters, ip, ma.ActionAccept)
	})
	if err != nil {
		return nil, err
	}

	bannedPeerIds, err := gc.BannedPeerIds()
	if err != nil {
		return nil, err
	}
	bannedPeers := peer.NewSet()
	err = capnpPeerIdListForeach(bannedPeerIds, func(peerID string) error {
		id := peer.ID(peerID)
		bannedPeers.Add(id)
		return nil
	})
	if err != nil {
		return nil, err
	}

	trustedPeerIds, err := gc.TrustedPeerIds()
	if err != nil {
		return nil, err
	}
	trustedPeers := peer.NewSet()
	err = capnpPeerIdListForeach(trustedPeerIds, func(peerID string) error {
		id := peer.ID(peerID)
		trustedPeers.Add(id)
		return nil
	})
	if err != nil {
		return nil, err
	}
	for _, peer := range addedPeers {
		trustedPeers.Add(peer.ID)
	}

	return codanet.NewCodaGatingState(bannedAddrFilters, trustedAddrFilters, bannedPeers, trustedPeers), nil
}

func panicOnErr(err error) {
	if err != nil {
		panic(err)
	}
}

func mkMsg(f func(*capnp.Segment)) *capnp.Message {
	msg, seg, err := capnp.NewMessage(capnp.SingleSegment(nil))
	panicOnErr(err)
	f(seg)
	return msg
}

func setNanoTime(ns *ipc.UnixNano, t time.Time) {
	ns.SetNanoSec(t.UnixNano())
}

func mkRpcRespError(seqno uint64, rpcRespErr error) *capnp.Message {
	if rpcRespErr == nil {
		panic("mkRpcRespError: nil error")
	}
	return mkMsg(func(seg *capnp.Segment) {
		m, err := ipc.NewRootDaemonInterface_Message(seg)
		panicOnErr(err)
		resp, err := m.NewRpcResponse()
		panicOnErr(err)
		h, err := resp.NewHeader()
		panicOnErr(err)
		ns, err := h.NewTimeSent()
		panicOnErr(err)
		setNanoTime(&ns, time.Now())
		h.SetSeqNumber(seqno)
		panicOnErr(resp.SetError(rpcRespErr.Error()))
	})
}

func mkRpcRespSuccess(seqno uint64, f func(*ipc.Libp2pHelperInterface_RpcResponseSuccess)) *capnp.Message {
	return mkMsg(func(seg *capnp.Segment) {
		m, err := ipc.NewRootDaemonInterface_Message(seg)
		panicOnErr(err)
		resp, err := m.NewRpcResponse()
		panicOnErr(err)
		h, err := resp.NewHeader()
		panicOnErr(err)
		ns, err := h.NewTimeSent()
		panicOnErr(err)
		setNanoTime(&ns, time.Now())
		h.SetSeqNumber(seqno)
		succ, err := resp.NewSuccess()
		panicOnErr(err)
		f(&succ)
	})
}

func mkPushMsg(f func(ipc.DaemonInterface_PushMessage)) *capnp.Message {
	return mkMsg(func(seg *capnp.Segment) {
		m, err := ipc.NewRootDaemonInterface_Message(seg)
		panicOnErr(err)
		pm, err := m.NewPushMessage()
		panicOnErr(err)
		h, err := pm.NewHeader()
		panicOnErr(err)
		ns, err := h.NewTimeSent()
		panicOnErr(err)
		setNanoTime(&ns, time.Now())
		f(pm)
	})
}

func mkPeerConnectedUpcall(peerId string) *capnp.Message {
	return mkPushMsg(func(m ipc.DaemonInterface_PushMessage) {
		pc, err := m.NewPeerConnected()
		panicOnErr(err)
		pid, err := pc.NewPeerId()
		panicOnErr(err)
		pid.SetId(peerId)
	})
}

func mkPeerDisconnectedUpcall(peerId string) *capnp.Message {
	return mkPushMsg(func(m ipc.DaemonInterface_PushMessage) {
		pc, err := m.NewPeerDisconnected()
		panicOnErr(err)
		pid, err := pc.NewPeerId()
		panicOnErr(err)
		panicOnErr(pid.SetId(peerId))
	})
}
func readPeerInfo(pi ipc.PeerInfo) (*codaPeerInfo, error) {
	pid, err := pi.PeerId()
	if err != nil {
		return nil, err
	}
	peerId, err := pid.Id()
	if err != nil {
		return nil, err
	}
	host, err := pi.Host()
	if err != nil {
		return nil, err
	}
	port := pi.Libp2pPort()
	return &codaPeerInfo{PeerID: peerId, Host: host, Libp2pPort: port}, nil
}
func setPeerInfo(pi ipc.PeerInfo, info *codaPeerInfo) {
	pid, err := pi.NewPeerId()
	panicOnErr(err)
	panicOnErr(pid.SetId(info.PeerID))
	panicOnErr(pi.SetHost(info.Host))
	pi.SetLibp2pPort(info.Libp2pPort)
}

func mkIncomingStreamUpcall(peer *codaPeerInfo, streamIdx uint64, protocol string) *capnp.Message {
	return mkPushMsg(func(m ipc.DaemonInterface_PushMessage) {
		pc, err := m.NewIncomingStream()
		panicOnErr(err)
		sid, err := pc.NewStreamId()
		panicOnErr(err)
		sid.SetId(streamIdx)
		panicOnErr(pc.SetProtocol(protocol))
		pi, err := pc.NewPeer()
		panicOnErr(err)
		setPeerInfo(pi, peer)
	})
}

func mkGossipReceivedUpcall(sender *codaPeerInfo, expiration time.Time, seenAt time.Time, data []byte, seqno uint64, subIdx uint64) *capnp.Message {
	return mkPushMsg(func(m ipc.DaemonInterface_PushMessage) {
		gr, err := m.NewGossipReceived()
		panicOnErr(err)

		pi, err := gr.NewSender()
		panicOnErr(err)
		setPeerInfo(pi, sender)

		sa, err := gr.NewSeenAt()
		panicOnErr(err)
		setNanoTime(&sa, seenAt)

		exp, err := gr.NewExpiration()
		panicOnErr(err)
		setNanoTime(&exp, expiration)

		subId, err := gr.NewSubscriptionId()
		panicOnErr(err)
		subId.SetId(subIdx)

		gr.SetValidationSeqNumber(seqno)
		panicOnErr(gr.SetData(data))
	})
}

func mkStreamLostUpcall(streamIdx uint64, reason string) *capnp.Message {
	return mkPushMsg(func(m ipc.DaemonInterface_PushMessage) {
		sl, err := m.NewStreamLost()
		panicOnErr(err)
		panicOnErr(sl.SetReason(reason))
		sid, err := sl.NewStreamId()
		panicOnErr(err)
		sid.SetId(streamIdx)
	})
}

func mkStreamCompleteUpcall(streamIdx uint64) *capnp.Message {
	return mkPushMsg(func(m ipc.DaemonInterface_PushMessage) {
		sl, err := m.NewStreamComplete()
		panicOnErr(err)
		sid, err := sl.NewStreamId()
		panicOnErr(err)
		sid.SetId(streamIdx)
	})
}

func mkStreamMessageReceivedUpcall(streamIdx uint64, data []byte) *capnp.Message {
	return mkPushMsg(func(m ipc.DaemonInterface_PushMessage) {
		im_, err := m.NewStreamMessageReceived()
		panicOnErr(err)
		im, err := im_.NewMsg()
		panicOnErr(err)
		sid, err := im.NewStreamId()
		panicOnErr(err)
		sid.SetId(streamIdx)
		panicOnErr(im.SetData(data))
	})
}
