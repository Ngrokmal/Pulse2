import 'call_state.dart' show RawStat;

/// Reads a finite number from a raw statistics value. Strings are accepted
/// because some platforms report 64-bit counters as text. Anything else,
/// NaN and infinity count as "not available".
double? statNumber(Object? value) {
  if (value == null) return null;
  double? parsed;
  if (value is num) {
    parsed = value.toDouble();
  } else if (value is String) {
    parsed = double.tryParse(value);
  }
  if (parsed == null || !parsed.isFinite) return null;
  return parsed;
}

bool? _statBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    if (value == 'true') return true;
    if (value == 'false') return false;
  }
  return null;
}

String? _statString(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return value;
}

int? _toInt(double? value) => value?.round();

/// One reading of the WebRTC statistics, reduced to the fields this app
/// uses. Every field is nullable: `null` means "the platform did not report
/// it", never zero. Counters are cumulative since the peer connection was
/// created; rates are computed from two samples by [CallStatsTracker].
class CallStatsSample {
  const CallStatsSample({
    required this.timestampMs,
    this.txVideoBytes,
    this.txVideoPackets,
    this.txVideoFrames,
    this.txVideoWidth,
    this.txVideoHeight,
    this.txVideoFps,
    this.txQualityLimitation,
    this.txEncoder,
    this.txVideoCodec,
    this.rxVideoBytes,
    this.rxVideoPackets,
    this.rxVideoPacketsLost,
    this.rxVideoFrames,
    this.rxVideoWidth,
    this.rxVideoHeight,
    this.rxVideoFps,
    this.rxVideoJitterMs,
    this.rxDecoder,
    this.rxVideoCodec,
    this.txAudioBytes,
    this.rxAudioBytes,
    this.rxAudioPackets,
    this.rxAudioPacketsLost,
    this.rxAudioJitterMs,
    this.remoteVideoPacketsLost,
    this.remoteVideoRttMs,
    this.remoteAudioRttMs,
    this.pairRttMs,
    this.availableOutgoingKbps,
    this.pairBytesSent,
    this.pairBytesReceived,
    this.localCandidateType,
    this.remoteCandidateType,
    this.candidateProtocol,
    this.networkType,
  });

  /// Monotonic time in milliseconds, supplied by the caller (not the wall
  /// clock, so clock changes cannot produce negative intervals).
  final int timestampMs;

  // Outgoing video.
  final double? txVideoBytes;
  final double? txVideoPackets;
  final double? txVideoFrames;
  final int? txVideoWidth;
  final int? txVideoHeight;
  final double? txVideoFps;

  /// `none`, `cpu`, `bandwidth` or `other`, as reported by the encoder.
  final String? txQualityLimitation;
  final String? txEncoder;
  final String? txVideoCodec;

  // Incoming video.
  final double? rxVideoBytes;
  final double? rxVideoPackets;
  final double? rxVideoPacketsLost;
  final double? rxVideoFrames;
  final int? rxVideoWidth;
  final int? rxVideoHeight;
  final double? rxVideoFps;
  final double? rxVideoJitterMs;
  final String? rxDecoder;
  final String? rxVideoCodec;

  // Audio.
  final double? txAudioBytes;
  final double? rxAudioBytes;
  final double? rxAudioPackets;
  final double? rxAudioPacketsLost;
  final double? rxAudioJitterMs;

  // What the other phone reports about OUR outgoing streams
  // (`remote-inbound-rtp`, built from RTCP receiver reports).
  final double? remoteVideoPacketsLost;
  final double? remoteVideoRttMs;
  final double? remoteAudioRttMs;

  // Selected ICE candidate pair. Addresses are deliberately not kept.
  final double? pairRttMs;
  final double? availableOutgoingKbps;
  final double? pairBytesSent;
  final double? pairBytesReceived;
  final String? localCandidateType;
  final String? remoteCandidateType;
  final String? candidateProtocol;
  final String? networkType;
}

/// Turns raw `getStats` entries into a [CallStatsSample].
class CallStatsParser {
  const CallStatsParser();

  CallStatsSample parse(Iterable<RawStat> stats, {required int timestampMs}) {
    final list = stats.toList(growable: false);

    final byId = <String, RawStat>{};
    for (final stat in list) {
      final id = stat.id;
      if (id != null) byId[id] = stat;
    }

    String? codecName(Object? codecId) {
      if (codecId is! String) return null;
      final mime = _statString(byId[codecId]?.values['mimeType']);
      if (mime == null) return null;
      final slash = mime.indexOf('/');
      return slash >= 0 && slash < mime.length - 1
          ? mime.substring(slash + 1)
          : mime;
    }

    // Outgoing video.
    double? txVideoBytes;
    double? txVideoPackets;
    double? txVideoFrames;
    int? txW;
    int? txH;
    double? txFps;
    String? txLimit;
    String? txEncoder;
    String? txCodec;
    // Incoming video.
    double? rxVideoBytes;
    double? rxVideoPackets;
    double? rxVideoLost;
    double? rxVideoFrames;
    int? rxW;
    int? rxH;
    double? rxFps;
    double? rxVideoJitter;
    String? rxDecoder;
    String? rxCodec;
    // Audio.
    double? txAudioBytes;
    double? rxAudioBytes;
    double? rxAudioPackets;
    double? rxAudioLost;
    double? rxAudioJitter;
    // Remote view of our streams.
    double? remoteVideoLost;
    double? remoteVideoRtt;
    double? remoteAudioRtt;

    double? add(double? total, double? value) =>
        value == null ? total : (total ?? 0) + value;
    double? maxOf(double? a, double? b) =>
        a == null ? b : (b == null ? a : (a > b ? a : b));

    for (final stat in list) {
      final v = stat.values;
      final kind = _statString(v['kind'] ?? v['mediaType']);
      switch (stat.type) {
        case 'outbound-rtp':
          if (kind == 'video') {
            txVideoBytes = add(txVideoBytes, statNumber(v['bytesSent']));
            txVideoPackets = add(txVideoPackets, statNumber(v['packetsSent']));
            txVideoFrames = add(
              txVideoFrames,
              statNumber(v['framesEncoded'] ?? v['framesSent']),
            );
            final w = _toInt(statNumber(v['frameWidth']));
            final h = _toInt(statNumber(v['frameHeight']));
            if (w != null && h != null && w > 0 && h > 0) {
              if (txW == null || w * h > txW * (txH ?? 0)) {
                txW = w;
                txH = h;
              }
            }
            txFps = maxOf(txFps, statNumber(v['framesPerSecond']));
            txLimit = _statString(v['qualityLimitationReason']) ?? txLimit;
            txEncoder = _statString(v['encoderImplementation']) ?? txEncoder;
            txCodec = codecName(v['codecId']) ?? txCodec;
          } else if (kind == 'audio') {
            txAudioBytes = add(txAudioBytes, statNumber(v['bytesSent']));
          }
        case 'inbound-rtp':
          if (kind == 'video') {
            rxVideoBytes = add(rxVideoBytes, statNumber(v['bytesReceived']));
            rxVideoPackets = add(
              rxVideoPackets,
              statNumber(v['packetsReceived']),
            );
            rxVideoLost = add(rxVideoLost, statNumber(v['packetsLost']));
            rxVideoFrames = add(rxVideoFrames, statNumber(v['framesDecoded']));
            final w = _toInt(statNumber(v['frameWidth']));
            final h = _toInt(statNumber(v['frameHeight']));
            if (w != null && h != null && w > 0 && h > 0) {
              rxW = w;
              rxH = h;
            }
            rxFps = maxOf(rxFps, statNumber(v['framesPerSecond']));
            final jitter = statNumber(v['jitter']);
            if (jitter != null)
              rxVideoJitter = maxOf(rxVideoJitter, jitter * 1000);
            rxDecoder = _statString(v['decoderImplementation']) ?? rxDecoder;
            rxCodec = codecName(v['codecId']) ?? rxCodec;
          } else if (kind == 'audio') {
            rxAudioBytes = add(rxAudioBytes, statNumber(v['bytesReceived']));
            rxAudioPackets = add(
              rxAudioPackets,
              statNumber(v['packetsReceived']),
            );
            rxAudioLost = add(rxAudioLost, statNumber(v['packetsLost']));
            final jitter = statNumber(v['jitter']);
            if (jitter != null)
              rxAudioJitter = maxOf(rxAudioJitter, jitter * 1000);
          }
        case 'remote-inbound-rtp':
          final rtt = statNumber(v['roundTripTime']);
          if (kind == 'video') {
            remoteVideoLost = add(
              remoteVideoLost,
              statNumber(v['packetsLost']),
            );
            if (rtt != null) remoteVideoRtt = rtt * 1000;
          } else if (kind == 'audio') {
            if (rtt != null) remoteAudioRtt = rtt * 1000;
          }
      }
    }

    // Selected candidate pair: prefer the transport's explicit pointer,
    // otherwise a nominated, succeeded pair.
    RawStat? pair;
    for (final stat in list) {
      if (stat.type != 'transport') continue;
      final pointer = stat.values['selectedCandidatePairId'];
      if (pointer is String && byId[pointer] != null) {
        pair = byId[pointer];
        break;
      }
    }
    if (pair == null) {
      for (final stat in list) {
        if (stat.type != 'candidate-pair') continue;
        final selected = _statBool(stat.values['selected']) == true;
        final nominated = _statBool(stat.values['nominated']) == true;
        final succeeded = stat.values['state'] == 'succeeded';
        if (selected || (nominated && succeeded)) {
          pair = stat;
          break;
        }
      }
    }

    double? pairRtt;
    double? outgoingKbps;
    double? pairSent;
    double? pairReceived;
    String? localType;
    String? remoteType;
    String? protocol;
    String? network;
    if (pair != null) {
      final v = pair.values;
      final rtt = statNumber(v['currentRoundTripTime']);
      if (rtt != null) pairRtt = rtt * 1000;
      final bps = statNumber(v['availableOutgoingBitrate']);
      if (bps != null) outgoingKbps = bps / 1000;
      pairSent = statNumber(v['bytesSent']);
      pairReceived = statNumber(v['bytesReceived']);
      final local = byId[v['localCandidateId']];
      final remote = byId[v['remoteCandidateId']];
      localType = _statString(local?.values['candidateType']);
      remoteType = _statString(remote?.values['candidateType']);
      protocol = _statString(local?.values['protocol']);
      network = _statString(local?.values['networkType']);
    }

    return CallStatsSample(
      timestampMs: timestampMs,
      txVideoBytes: txVideoBytes,
      txVideoPackets: txVideoPackets,
      txVideoFrames: txVideoFrames,
      txVideoWidth: txW,
      txVideoHeight: txH,
      txVideoFps: txFps,
      txQualityLimitation: txLimit,
      txEncoder: txEncoder,
      txVideoCodec: txCodec,
      rxVideoBytes: rxVideoBytes,
      rxVideoPackets: rxVideoPackets,
      rxVideoPacketsLost: rxVideoLost,
      rxVideoFrames: rxVideoFrames,
      rxVideoWidth: rxW,
      rxVideoHeight: rxH,
      rxVideoFps: rxFps,
      rxVideoJitterMs: rxVideoJitter,
      rxDecoder: rxDecoder,
      rxVideoCodec: rxCodec,
      txAudioBytes: txAudioBytes,
      rxAudioBytes: rxAudioBytes,
      rxAudioPackets: rxAudioPackets,
      rxAudioPacketsLost: rxAudioLost,
      rxAudioJitterMs: rxAudioJitter,
      remoteVideoPacketsLost: remoteVideoLost,
      remoteVideoRttMs: remoteVideoRtt,
      remoteAudioRttMs: remoteAudioRtt,
      pairRttMs: pairRtt,
      availableOutgoingKbps: outgoingKbps,
      pairBytesSent: pairSent,
      pairBytesReceived: pairReceived,
      localCandidateType: localType,
      remoteCandidateType: remoteType,
      candidateProtocol: protocol,
      networkType: network,
    );
  }
}

/// Measurements for one sampling interval. `null` always means
/// "unavailable" and must be shown as such, never as zero.
class CallMetrics {
  const CallMetrics({
    this.intervalValid = false,
    this.txVideoKbps,
    this.rxVideoKbps,
    this.txAudioKbps,
    this.rxAudioKbps,
    this.txVideoFps,
    this.rxVideoFps,
    this.rxVideoLossPct,
    this.rxAudioLossPct,
    this.outboundLossPct,
    this.rxBytesDelta,
    this.rxStalled = false,
    this.rttMs,
    this.jitterMs,
    this.txWidth,
    this.txHeight,
    this.rxWidth,
    this.rxHeight,
    this.qualityLimitation,
    this.txEncoder,
    this.rxDecoder,
    this.txCodec,
    this.rxCodec,
    this.availableOutgoingKbps,
    this.totalBytesSent,
    this.totalBytesReceived,
    this.localCandidateType,
    this.remoteCandidateType,
    this.candidateProtocol,
    this.networkType,
  });

  static const CallMetrics unavailable = CallMetrics();

  /// False for the first sample, after a gap, or after a counter reset:
  /// rates are then unavailable, but instantaneous fields may still be set.
  final bool intervalValid;

  // Rates over the interval, in kilobits per second.
  final double? txVideoKbps;
  final double? rxVideoKbps;
  final double? txAudioKbps;
  final double? rxAudioKbps;

  /// Reported frame rate, or frames-per-interval when not reported.
  final double? txVideoFps;
  final double? rxVideoFps;

  /// Loss over the interval for what THIS phone receives, in percent.
  final double? rxVideoLossPct;
  final double? rxAudioLossPct;

  /// Loss over the interval for what this phone SENDS, as reported by the
  /// other phone (RTCP), in percent.
  final double? outboundLossPct;

  /// Bytes received (audio + video) during the interval, when measurable.
  final double? rxBytesDelta;

  /// True when the interval is valid and no media bytes arrived at all.
  final bool rxStalled;

  final double? rttMs;
  final double? jitterMs;

  final int? txWidth;
  final int? txHeight;
  final int? rxWidth;
  final int? rxHeight;
  final String? qualityLimitation;
  final String? txEncoder;
  final String? rxDecoder;
  final String? txCodec;
  final String? rxCodec;
  final double? availableOutgoingKbps;
  final double? totalBytesSent;
  final double? totalBytesReceived;
  final String? localCandidateType;
  final String? remoteCandidateType;
  final String? candidateProtocol;
  final String? networkType;

  /// Worst receive-side loss available, in percent.
  double? get worstRxLossPct {
    final video = rxVideoLossPct;
    final audio = rxAudioLossPct;
    if (video == null) return audio;
    if (audio == null) return video;
    return video > audio ? video : audio;
  }

  /// True when at least one quality-relevant number is present.
  bool get hasQualityData =>
      worstRxLossPct != null ||
      outboundLossPct != null ||
      rttMs != null ||
      jitterMs != null ||
      rxStalled;
}

/// Computes [CallMetrics] from consecutive samples.
///
/// Rates use the difference of cumulative counters over the elapsed time.
/// An interval is rejected (rates unavailable) when it is not positive,
/// shorter than [minIntervalMs], longer than [maxGapMs], or when a counter
/// went backwards (the peer connection was replaced).
class CallStatsTracker {
  CallStatsTracker({this.minIntervalMs = 500, this.maxGapMs = 10000});

  final int minIntervalMs;
  final int maxGapMs;

  CallStatsSample? _previous;

  bool get hasBaseline => _previous != null;

  /// Forgets the previous sample (new call, or app resumed from background).
  void reset() => _previous = null;

  CallMetrics add(CallStatsSample current) {
    final previous = _previous;
    var intervalValid = false;
    var dtSeconds = 0.0;
    if (previous != null) {
      final dt = current.timestampMs - previous.timestampMs;
      if (dt <= 0) {
        // Same or earlier timestamp: keep the old baseline, learn nothing.
        return _instant(current);
      }
      if (dt >= minIntervalMs && dt <= maxGapMs) {
        intervalValid = true;
        dtSeconds = dt / 1000.0;
      }
    }
    _previous = current;
    if (!intervalValid || previous == null) return _instant(current);

    double? kbps(double? before, double? after) {
      if (before == null || after == null) return null;
      final delta = after - before;
      if (delta < 0) return null; // counter reset
      return delta * 8 / 1000 / dtSeconds;
    }

    double? delta(double? before, double? after) {
      if (before == null || after == null) return null;
      final d = after - before;
      return d < 0 ? null : d;
    }

    double? lossPct(
      double? receivedBefore,
      double? receivedAfter,
      double? lostBefore,
      double? lostAfter, {
      bool receivedIncludesLost = false,
    }) {
      final received = delta(receivedBefore, receivedAfter);
      if (received == null || lostBefore == null || lostAfter == null) {
        return null;
      }
      // packetsLost may legitimately shrink (late packets); never negative.
      final lostRaw = lostAfter - lostBefore;
      final lost = lostRaw < 0 ? 0.0 : lostRaw;
      // Received-side counters exclude lost packets; sent-side counters
      // already include them.
      final total = receivedIncludesLost ? received : received + lost;
      // No packets in the interval is "no information", not "0 % loss".
      if (total <= 0) return null;
      return 100 * lost / total;
    }

    double? fps(double? reported, double? framesBefore, double? framesAfter) {
      if (reported != null && reported >= 0) return reported;
      final frames = delta(framesBefore, framesAfter);
      return frames == null ? null : frames / dtSeconds;
    }

    final rxVideoDelta = delta(previous.rxVideoBytes, current.rxVideoBytes);
    final rxAudioDelta = delta(previous.rxAudioBytes, current.rxAudioBytes);
    double? rxBytesDelta;
    if (rxVideoDelta != null || rxAudioDelta != null) {
      rxBytesDelta = (rxVideoDelta ?? 0) + (rxAudioDelta ?? 0);
    }
    // A stall needs evidence from every counter that exists, and no growth.
    final stalled =
        rxBytesDelta != null &&
        rxBytesDelta == 0 &&
        (current.rxVideoBytes != null || current.rxAudioBytes != null);

    final base = _instant(current);
    return CallMetrics(
      intervalValid: true,
      txVideoKbps: kbps(previous.txVideoBytes, current.txVideoBytes),
      rxVideoKbps: kbps(previous.rxVideoBytes, current.rxVideoBytes),
      txAudioKbps: kbps(previous.txAudioBytes, current.txAudioBytes),
      rxAudioKbps: kbps(previous.rxAudioBytes, current.rxAudioBytes),
      txVideoFps: fps(
        current.txVideoFps,
        previous.txVideoFrames,
        current.txVideoFrames,
      ),
      rxVideoFps: fps(
        current.rxVideoFps,
        previous.rxVideoFrames,
        current.rxVideoFrames,
      ),
      rxVideoLossPct: lossPct(
        previous.rxVideoPackets,
        current.rxVideoPackets,
        previous.rxVideoPacketsLost,
        current.rxVideoPacketsLost,
      ),
      rxAudioLossPct: lossPct(
        previous.rxAudioPackets,
        current.rxAudioPackets,
        previous.rxAudioPacketsLost,
        current.rxAudioPacketsLost,
      ),
      outboundLossPct: lossPct(
        previous.txVideoPackets,
        current.txVideoPackets,
        previous.remoteVideoPacketsLost,
        current.remoteVideoPacketsLost,
        receivedIncludesLost: true,
      ),
      rxBytesDelta: rxBytesDelta,
      rxStalled: stalled,
      rttMs: base.rttMs,
      jitterMs: base.jitterMs,
      txWidth: base.txWidth,
      txHeight: base.txHeight,
      rxWidth: base.rxWidth,
      rxHeight: base.rxHeight,
      qualityLimitation: base.qualityLimitation,
      txEncoder: base.txEncoder,
      rxDecoder: base.rxDecoder,
      txCodec: base.txCodec,
      rxCodec: base.rxCodec,
      availableOutgoingKbps: base.availableOutgoingKbps,
      totalBytesSent: base.totalBytesSent,
      totalBytesReceived: base.totalBytesReceived,
      localCandidateType: base.localCandidateType,
      remoteCandidateType: base.remoteCandidateType,
      candidateProtocol: base.candidateProtocol,
      networkType: base.networkType,
    );
  }

  /// Fields that do not need a previous sample.
  CallMetrics _instant(CallStatsSample s) {
    double? rtt = s.pairRttMs ?? s.remoteVideoRttMs ?? s.remoteAudioRttMs;
    if (rtt != null && rtt < 0) rtt = null;
    double? jitter = s.rxVideoJitterMs;
    final audioJitter = s.rxAudioJitterMs;
    if (jitter == null || (audioJitter != null && audioJitter > jitter)) {
      jitter = audioJitter;
    }
    if (jitter != null && jitter < 0) jitter = null;

    double? sum(double? a, double? b) =>
        (a == null && b == null) ? null : (a ?? 0) + (b ?? 0);

    return CallMetrics(
      rttMs: rtt,
      jitterMs: jitter,
      txVideoFps: s.txVideoFps,
      rxVideoFps: s.rxVideoFps,
      txWidth: s.txVideoWidth,
      txHeight: s.txVideoHeight,
      rxWidth: s.rxVideoWidth,
      rxHeight: s.rxVideoHeight,
      qualityLimitation: s.txQualityLimitation,
      txEncoder: s.txEncoder,
      rxDecoder: s.rxDecoder,
      txCodec: s.txVideoCodec,
      rxCodec: s.rxVideoCodec,
      availableOutgoingKbps: s.availableOutgoingKbps,
      totalBytesSent: s.pairBytesSent ?? sum(s.txVideoBytes, s.txAudioBytes),
      totalBytesReceived:
          s.pairBytesReceived ?? sum(s.rxVideoBytes, s.rxAudioBytes),
      localCandidateType: s.localCandidateType,
      remoteCandidateType: s.remoteCandidateType,
      candidateProtocol: s.candidateProtocol,
      networkType: s.networkType,
    );
  }
}
