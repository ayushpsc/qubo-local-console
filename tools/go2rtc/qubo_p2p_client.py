"""Qubo Video Doorbell -> local H.264/AAC stream with optional talkback.

Speaks the doorbell's peer-to-peer protocol directly, so video never touches
the Qubo cloud. Written for go2rtc's `exec:` source: it writes MPEG-TS with
H.264 video and AAC audio to stdout. If audio is unavailable it falls back to
the original Annex-B H.264 output.

Protocol (reverse-engineered from the vendor app, Sep 2026):

  1) Ask the cloud to start a session. ``POST .../p2pCall`` with a client-chosen
     AES key and IV, and our LAN address as the UDP candidate. The cloud only
     signals; from here on the doorbell talks to us directly.

  2) ICE-style handshake over UDP. Every control frame starts with the magic
     ``244a2112`` and ends with a HMAC-SHA1 of the header+attributes keyed by
     the AES key we chose.
       - a Binding Request (0x0001) is answered with a Success (0x0101)
       - check A (attribute 0x7002) and check B (USERNAME 0x0025 = 0x70, then
         attribute 0x0200) are re-sent every two seconds

     Check B is the "go" signal; once the doorbell sees it, it starts sending
     RTP to the address we advertised.

  3) Each RTP packet carries AES-128-GCM ciphertext. The AAD is the 12-byte RTP
     header and the IV is the first 8 bytes of our IV XORed with the first 8
     bytes of the RTP header, followed by our IV's last 8 bytes. The 16-byte GCM
     tag is appended to the ciphertext.

  4) Video (payload type 96) is reassembled from FU-A fragments into Annex-B.
     Audio (payload type 97) is ADTS AAC. ffmpeg copy-muxes both elementary
     streams to MPEG-TS on stdout so go2rtc receives both tracks without an
     intermediate RTSP publisher.

  5) Optional talkback accepts PCMA/8 kHz from go2rtc on stdin, encodes it as
     AAC-LC/16 kHz, encrypts it as payload type 97 and sends it to the active
     doorbell peer. This direction is reverse-engineered and opt-in with
     ``QTALK=true``.

Usage:
    qubo_p2p_client.py <out.h264|-> [port]

    Invoke through `sh -c` in a go2rtc `exec:` source. When the output is `-`,
    go2rtc reads MPEG-TS (or video-only Annex-B H.264 fallback) from stdout.
    Do not append an ffmpeg-to-RTSP `{output}` stage; a short or delayed camera
    session can make that publisher exit and trigger competing P2P sessions.

Environment:
    QSP        service provider id          (default: Qubo's public constant)
    QDEVICE    doorbell device UUID         (required)
    QUNIT      unit UUID                    (required)
    QMOB       mobile device UUID, the `mobileUUID` and stream userAppID (required)
    QSOURCE    source device id sent in the request (default: your HA login id)
    QADVERT    LAN IP to advertise          (default: first outbound address)
    QPORT      local UDP port               (default: 49700)
    QQUALITY   low | high                    (default: low)
    QVIDEOFPS  generated video clock rate    (default: 10, observed doorbell rate)
    QDUR       seconds to run before exiting (default: 60). Raise it well past
               the longest expected viewing session: go2rtc does not restart a
               finished exec source, so exiting under a viewer kills their stream
               with nothing to replace it.
    QMEDIATIMEOUT  seconds to wait for the first media packet before giving up
               (default: 30). A session the doorbell never joins must not
               outlive the process that started it.
    QSTALLTIMEOUT  seconds a working session may go silent before giving up
               (default: 120).
    QAUDIO     mux decrypted ADTS AAC with video (default: true).
    QAUDIOWAIT seconds to wait for the first valid AAC packet before falling
               back to video-only H.264 (default: 8).
    QAUDIOGAINDB gain applied before AAC/Opus encoding (default: 20 dB).
    QTALK      enable experimental browser-to-doorbell audio (default: false).
    QTALKGAINDB gain applied to browser microphone audio before talkback AAC
               encoding (default: 12 dB; protected by a peak limiter).
    QTALKSOCKET local Unix datagram socket used by the separate go2rtc
               backchannel exec (default: /tmp/qubo_talkback_<QPORT>.sock).
    QFFMPEG    ffmpeg executable used for muxing/encoding (default: ffmpeg).
    QSTORE     path to Home Assistant's core.config_entries
    QACCESS / QREFRESH / QUUID / QDEVICEID
               explicit credentials, used instead of reading QSTORE
"""

from __future__ import annotations

import hashlib
import hmac
import importlib
import json
import math
import os
import queue
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

BASE = "https://srvcapp.platform.quboworld.com:443"

# Qubo's public application id, the same constant the vendor app sends.
APP_ID = "934488E68332E88B1E0F9AF552840184955629777525A195949C0BE97DEF6455"
# qubopy and the Home Assistant integration use the Android package id for
# session renewal, while the stream-manager requests use the observed app id.
AUTH_APP_ID = "com.hero.iot"

# Qubo's service provider id. Also a public constant, identical for all
# accounts.
DEFAULT_SP = "d10e4bfb0153496e8e8bb955f7ebe413"

MAGIC = bytes.fromhex("244a2112")
SC = bytes.fromhex("00000001")  # Annex-B start code

PT_VIDEO = 96
PT_AUDIO = 97

BIND_REQUEST = 0x0001
BIND_SUCCESS = 0x0101
CHECK_INTERVAL = 2.0
STALL_DROP_SECONDS = 0.5
ADTS_HEADER_MIN = 7
TALK_AUDIO_RATE = 16000
TALK_AUDIO_SAMPLES = 1024
TALK_MAX_UDP_PAYLOAD = 1200
TALK_BATCH_DELAY = 0.18

# How long to wait for the first media packet, and how long a session may go
# silent once it was working. Both exist so a session the doorbell never
# joins cannot outlive the process that started it.
MEDIA_TIMEOUT = float(os.environ.get("QMEDIATIMEOUT", "30"))
STALL_TIMEOUT = float(os.environ.get("QSTALLTIMEOUT", "120"))

# A fresh key and IV per process, which is also a fresh session: the doorbell
# uses exactly the values we hand it in the p2pCall request.
KEY = os.urandom(16)
IV = os.urandom(16)


def _env_bool(name: str, default: bool = False) -> bool:
    """Read a conventional true/false environment flag."""
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _require(name: str) -> str:
    """Return a required environment variable or explain what is missing."""
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"qubo: {name} is not set")
    return value


def _install_crypto(libdir: str) -> None:
    """Import AES-GCM, installing `cryptography` into libdir once if needed."""
    for candidate in ("", libdir):
        if candidate:
            sys.path.insert(0, candidate)
        try:
            import cryptography  # noqa: F401

            return
        except ImportError:
            continue

    import subprocess

    os.makedirs(libdir, exist_ok=True)
    subprocess.run(
        [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--no-cache-dir",
            "--target",
            libdir,
            "cryptography",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=300,
    )
    sys.path.insert(0, libdir)
    # The path may have been probed before pip created it, so Python's finder
    # can otherwise retain an empty-directory cache until the next process.
    importlib.invalidate_caches()


_libdir = os.environ.get("QLIBS") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "_libs"
)
_install_crypto(_libdir)

from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: E402


def _adts_frame_length(data: bytes | bytearray, offset: int = 0) -> int | None:
    """Return one ADTS frame length, or None when the header is incomplete."""
    if len(data) - offset < ADTS_HEADER_MIN:
        return None
    if data[offset] != 0xFF or (data[offset + 1] & 0xF6) != 0xF0:
        return None
    length = (
        ((data[offset + 3] & 0x03) << 11)
        | (data[offset + 4] << 3)
        | (data[offset + 5] >> 5)
    )
    header_length = 7 if data[offset + 1] & 0x01 else 9
    if length < header_length:
        return None
    return length


def _is_adts(data: bytes) -> bool:
    """Validate that a payload contains one or more complete ADTS frames."""
    offset = 0
    while offset < len(data):
        length = _adts_frame_length(data, offset)
        if length is None or offset + length > len(data):
            return False
        offset += length
    return offset > 0


def _unwrap_audio_payload(data: bytes) -> tuple[bytes | None, bool]:
    """Return ADTS bytes and whether an MPEG4-GENERIC AU header was removed.

    The doorbell prefixes its ADTS frame with RFC 3640-style AU headers:
    16 bits of AU-headers-length followed by one or more 13-bit size + 3-bit
    index fields. Observed packets use one 16-bit header (00 10 xx xx).
    """
    if _is_adts(data):
        return data, False
    if len(data) < 4:
        return None, False
    header_bits = struct.unpack("!H", data[:2])[0]
    if header_bits == 0 or header_bits % 16 != 0:
        return None, False
    header_bytes = header_bits // 8
    payload_offset = 2 + header_bytes
    if payload_offset > len(data):
        return None, False

    sizes = []
    for offset in range(2, payload_offset, 2):
        header = struct.unpack("!H", data[offset : offset + 2])[0]
        size = header >> 3
        if size == 0:
            return None, False
        sizes.append(size)
    if sum(sizes) != len(data) - payload_offset:
        return None, False

    cursor = payload_offset
    frames = bytearray()
    for size in sizes:
        frame = data[cursor : cursor + size]
        if not _is_adts(frame):
            return None, False
        frames.extend(frame)
        cursor += size
    return bytes(frames), True


def _wrap_audio_frames(frames: list[bytes]) -> bytes:
    """Wrap ADTS frames in the multi-AU MPEG4-GENERIC form Qubo sends."""
    if not frames:
        raise ValueError("talkback payload must contain at least one AAC frame")
    headers = bytearray()
    for frame in frames:
        if not _is_adts(frame):
            raise ValueError("talkback payload must be complete ADTS AAC")
        if len(frame) > 0x1FFF:
            raise ValueError("talkback AAC frame exceeds the 13-bit AU size field")
        headers.extend(struct.pack("!H", len(frame) << 3))
    return struct.pack("!H", len(headers) * 8) + headers + b"".join(frames)


def _wrap_audio_payload(frame: bytes) -> bytes:
    """Compatibility wrapper for one ADTS AAC access unit."""
    return _wrap_audio_frames([frame])


class _OrderedPackets:
    """Small per-track RTP reorder buffer with loss recovery by skipping gaps."""

    def __init__(self) -> None:
        self.pending: dict[int, bytes] = {}
        self.next_seq: int | None = None
        self.last_flush = time.monotonic()

    def push(self, seq: int, payload: bytes, emit) -> None:
        self.pending[seq] = payload
        if self.next_seq is None:
            self.next_seq = seq
        self._flush_contiguous(emit)
        if (
            self.pending
            and self.next_seq not in self.pending
            and time.monotonic() - self.last_flush > STALL_DROP_SECONDS
        ):
            # One or more UDP packets were lost. Advancing by only one sequence
            # number per timeout can leave a track stalled for minutes after a
            # larger gap. Resume at the closest packet ahead in the 16-bit RTP
            # sequence space, then emit anything contiguous behind it.
            self.next_seq = min(
                self.pending,
                key=lambda candidate: (candidate - self.next_seq) & 0xFFFF,
            )
            self._flush_contiguous(emit)

    def _flush_contiguous(self, emit) -> None:
        while self.next_seq in self.pending:
            emit(self.pending.pop(self.next_seq))
            self.next_seq = (self.next_seq + 1) & 0xFFFF
            self.last_flush = time.monotonic()


class _AsyncPipeWriter:
    """Feed one ffmpeg input without blocking the UDP receive loop.

    ffmpeg probes its inputs sequentially. Writing two live inputs from one
    thread can therefore deadlock: the caller fills the video pipe while
    ffmpeg is waiting for more audio, so neither side can advance. A dedicated
    writer per input lets both probes receive data concurrently.
    """

    MAX_PENDING = 2048
    _STOP = object()

    def __init__(self, fd: int, label: str) -> None:
        self.label = label
        self.pipe = os.fdopen(fd, "wb", buffering=0)
        self.pending: queue.Queue[bytes | object] = queue.Queue(
            maxsize=self.MAX_PENDING
        )
        self.error: BaseException | None = None
        self.thread = threading.Thread(
            target=self._run,
            name=f"qubo-ffmpeg-{label}",
            daemon=True,
        )
        self.thread.start()

    def _run(self) -> None:
        try:
            while True:
                item = self.pending.get()
                if item is self._STOP:
                    break
                self.pipe.write(item)
        except (BrokenPipeError, OSError) as err:
            self.error = err
        finally:
            try:
                self.pipe.close()
            except OSError:
                pass

    def write(self, data: bytes) -> None:
        if self.error is not None:
            raise BrokenPipeError(
                f"ffmpeg {self.label} input failed: {self.error}"
            ) from self.error
        if not self.thread.is_alive():
            raise BrokenPipeError(f"ffmpeg {self.label} input closed")
        try:
            self.pending.put(bytes(data), timeout=1)
        except queue.Full as err:
            raise BrokenPipeError(
                f"ffmpeg {self.label} input queue stalled"
            ) from err

    def finish(self) -> bool:
        """Request a clean EOF; return false if the input is already stuck."""
        if not self.thread.is_alive():
            return True
        try:
            self.pending.put(self._STOP, timeout=1)
            return True
        except queue.Full:
            return False

    def join(self, timeout: float) -> None:
        self.thread.join(timeout)


class _AvMuxer:
    """Publish H.264 plus corrected AAC audio as MPEG-TS."""

    def __init__(
        self,
        out_path: str,
        ffmpeg: str,
        video_fps: float = 10,
        audio_gain_db: float = 20,
    ) -> None:
        video_read, video_write = os.pipe()
        audio_read, audio_write = os.pipe()
        destination = "pipe:1" if out_path == "-" else out_path
        audio_filter = (
            f"[1:a:0]volume={audio_gain_db:g}dB,"
            "alimiter=limit=0.95:attack=5:release=50[aac]"
        )
        command = [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "fatal" if out_path == "-" else "warning",
            "-fflags",
            "+genpts+nobuffer",
            "-probesize",
            "65536",
            "-analyzeduration",
            "1000000",
            "-thread_queue_size",
            "256",
            "-use_wallclock_as_timestamps",
            "1",
            "-framerate",
            f"{video_fps:g}",
            "-f",
            "h264",
            "-i",
            f"pipe:{video_read}",
            "-thread_queue_size",
            "256",
            "-use_wallclock_as_timestamps",
            "1",
            "-f",
            "aac",
            "-i",
            f"pipe:{audio_read}",
            "-filter_complex",
            audio_filter,
            "-map",
            "0:v:0",
            "-map",
            "[aac]",
            "-c:v",
            "copy",
            "-c:a:0",
            "aac",
            "-profile:a:0",
            "aac_low",
            "-ar:a:0",
            "16000",
            "-ac:a:0",
            "1",
            "-b:a:0",
            "48k",
            "-avoid_negative_ts",
            "make_zero",
            "-max_interleave_delta",
            "1000000",
            "-mpegts_flags",
            "+resend_headers",
            "-muxdelay",
            "0",
            "-muxpreload",
            "0",
            "-flush_packets",
            "1",
            "-f",
            "mpegts",
            destination,
        ]
        if out_path != "-":
            command.insert(1, "-y")
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                pass_fds=(video_read, audio_read),
                close_fds=True,
            )
        except Exception:
            os.close(video_read)
            os.close(video_write)
            os.close(audio_read)
            os.close(audio_write)
            raise
        os.close(video_read)
        os.close(audio_read)
        self.video = _AsyncPipeWriter(video_write, "video")
        self.audio = _AsyncPipeWriter(audio_write, "audio")

    def _check(self) -> None:
        code = self.process.poll()
        if code is not None:
            raise BrokenPipeError(f"ffmpeg muxer exited with status {code}")

    def write_video(self, data: bytes) -> None:
        self._check()
        self.video.write(data)

    def write_audio(self, data: bytes) -> None:
        self._check()
        self.audio.write(data)

    def close(self) -> None:
        inputs = (self.video, self.audio)
        clean_eof = all(pipe.finish() for pipe in inputs)
        if clean_eof:
            for pipe in inputs:
                pipe.join(3)
            clean_eof = all(not pipe.thread.is_alive() for pipe in inputs)
        if not clean_eof and self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        for pipe in inputs:
            pipe.join(1)


class _MediaOutput:
    """Choose MPEG-TS A/V after seeing AAC, otherwise retain video fallback."""

    MAX_VIDEO_BACKLOG = 4 * 1024 * 1024

    def __init__(
        self,
        out_path: str,
        audio_enabled: bool,
        audio_wait: float,
        ffmpeg: str,
        video_fps: float = 10,
        audio_gain_db: float = 20,
    ) -> None:
        self.out_path = out_path
        self.audio_enabled = audio_enabled
        self.audio_wait = max(0.0, audio_wait)
        self.ffmpeg = ffmpeg
        self.video_fps = video_fps
        self.audio_gain_db = audio_gain_db
        self.started = time.monotonic()
        self.backlog = bytearray()
        self.direct = None
        self.muxer: _AvMuxer | None = None
        self.invalid_audio_reported = False
        self.au_header_reported = False
        if not audio_enabled:
            self._start_video_only("audio disabled")

    def _open_direct(self):
        return (
            sys.stdout.buffer
            if self.out_path == "-"
            else open(self.out_path, "wb", buffering=0)
        )

    def _start_video_only(self, reason: str) -> None:
        if self.direct is not None or self.muxer is not None:
            return
        self.direct = self._open_direct()
        if self.backlog:
            self.direct.write(self.backlog)
            self.backlog.clear()
        sys.stderr.write(f"qubo: using video-only H.264 ({reason})\n")
        sys.stderr.flush()

    def _start_av(self, first_audio: bytes) -> None:
        try:
            self.muxer = _AvMuxer(
                self.out_path,
                self.ffmpeg,
                self.video_fps,
                self.audio_gain_db,
            )
            # Queue audio before flushing video. ffmpeg probes the video input
            # first; pre-filling the audio pipe avoids a two-pipe startup
            # deadlock when it moves on to probe AAC.
            self.muxer.write_audio(first_audio)
            if self.backlog:
                self.muxer.write_video(bytes(self.backlog))
                self.backlog.clear()
            sys.stderr.write(
                "qubo: detected ADTS AAC; publishing H.264 + AAC "
                f"MPEG-TS (gain {self.audio_gain_db:g} dB)\n"
            )
            sys.stderr.flush()
        except (OSError, subprocess.SubprocessError) as err:
            if self.muxer is not None:
                self.muxer.close()
                self.muxer = None
            sys.stderr.write(f"qubo: audio muxer unavailable ({err}); falling back\n")
            self._start_video_only("ffmpeg muxer failed")

    def write(self, data: bytes) -> None:
        """File-like video writer used by the Annex-B reassembler."""
        if self.muxer is not None:
            self.muxer.write_video(data)
        elif self.direct is not None:
            self.direct.write(data)
        else:
            self.backlog.extend(data)
            if len(self.backlog) > self.MAX_VIDEO_BACKLOG:
                self._start_video_only("audio startup buffer filled")

    def flush(self) -> None:
        if self.direct is not None:
            self.direct.flush()

    def write_audio(self, data: bytes) -> None:
        if not self.audio_enabled or self.direct is not None:
            return
        audio, wrapped = _unwrap_audio_payload(data)
        if audio is None:
            if not self.invalid_audio_reported:
                prefix = data[:8].hex()
                sys.stderr.write(
                    "qubo: PT97 is not recognized ADTS/AU-header AAC "
                    f"(first bytes {prefix}); waiting before video-only fallback\n"
                )
                sys.stderr.flush()
                self.invalid_audio_reported = True
            return
        if wrapped and not self.au_header_reported:
            sys.stderr.write(
                "qubo: detected MPEG4-GENERIC AU header around ADTS AAC\n"
            )
            sys.stderr.flush()
            self.au_header_reported = True
        if self.muxer is not None:
            self.muxer.write_audio(audio)
            return
        self._start_av(audio)

    def tick(self) -> None:
        if (
            self.audio_enabled
            and self.direct is None
            and self.muxer is None
            and time.monotonic() - self.started >= self.audio_wait
        ):
            self._start_video_only("no valid AAC received")

    def close(self) -> None:
        if self.direct is None and self.muxer is None:
            self._start_video_only("session ended before AAC arrived")
        if self.muxer is not None:
            self.muxer.close()
        elif self.direct is not None:
            try:
                self.direct.flush()
            except (BrokenPipeError, OSError):
                pass
            if self.out_path != "-":
                self.direct.close()


def _talkback_ffmpeg_command(ffmpeg: str, gain_db: float) -> list[str]:
    linear_gain = 10 ** (gain_db / 20)
    return [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-fflags",
        "nobuffer",
        "-f",
        "alaw",
        "-ar",
        "8000",
        "-ac",
        "1",
        "-i",
        "pipe:0",
        "-vn",
        "-af",
        (
            f"alimiter=level_in={linear_gain:.6f}:limit=0.95:attack=1:"
            "release=50:level=false:latency=true"
        ),
        "-c:a",
        "aac",
        "-profile:a",
        "aac_low",
        "-ar",
        str(TALK_AUDIO_RATE),
        "-ac",
        "1",
        "-b:a",
        "32k",
        "-flush_packets",
        "1",
        "-f",
        "adts",
        "pipe:1",
    ]


class _TalkbackEncoder:
    """Encode PCMA chunks from the local bridge to complete ADTS AAC frames."""

    def __init__(self, ffmpeg: str, gain_db: float) -> None:
        self.frames: queue.Queue[bytes] = queue.Queue(maxsize=64)
        self.process = subprocess.Popen(
            _talkback_ffmpeg_command(ffmpeg, gain_db),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        self.stopped = threading.Event()
        self.output_thread = threading.Thread(target=self._read_frames, daemon=True)
        self.output_thread.start()

    def feed(self, chunk: bytes) -> None:
        """Feed one browser PCMA chunk into the persistent AAC encoder."""
        if not chunk or self.stopped.is_set():
            return
        assert self.process.stdin is not None
        try:
            self.process.stdin.write(chunk)
            self.process.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            self.stopped.set()

    def _read_frames(self) -> None:
        assert self.process.stdout is not None
        data = bytearray()
        try:
            while not self.stopped.is_set():
                # BufferedReader.read(4096) may wait for a full buffer, adding
                # roughly a second of microphone latency at 32 kbit/s. A raw
                # pipe read returns the AAC frames currently available.
                chunk = os.read(self.process.stdout.fileno(), 4096)
                if not chunk:
                    break
                data.extend(chunk)
                while len(data) >= ADTS_HEADER_MIN:
                    length = _adts_frame_length(data)
                    if length is None:
                        del data[0]
                        continue
                    if len(data) < length:
                        break
                    frame = bytes(data[:length])
                    del data[:length]
                    try:
                        self.frames.put_nowait(frame)
                    except queue.Full:
                        try:
                            self.frames.get_nowait()
                        except queue.Empty:
                            pass
                        self.frames.put_nowait(frame)
        except OSError:
            pass

    def drain(self, limit: int = 8) -> list[bytes]:
        result = []
        for _ in range(limit):
            try:
                result.append(self.frames.get_nowait())
            except queue.Empty:
                break
        return result

    def close(self) -> None:
        self.stopped.set()
        if self.process.stdin is not None:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)


class _TalkbackPacketizer:
    """Batch AAC access units like the native app without exceeding the MTU."""

    def __init__(
        self,
        max_udp_payload: int = TALK_MAX_UDP_PAYLOAD,
        max_delay: float = TALK_BATCH_DELAY,
    ) -> None:
        self.max_plaintext = max_udp_payload - 12 - 16
        self.max_delay = max_delay
        self.pending: list[tuple[bytes, float]] = []

    def add(self, frames: list[bytes], now: float | None = None) -> None:
        added_at = time.monotonic() if now is None else now
        self.pending.extend((frame, added_at) for frame in frames)

    def drain(self, now: float | None = None) -> list[list[bytes]]:
        current = time.monotonic() if now is None else now
        batches = []
        while self.pending:
            count = 0
            payload_size = 2
            for frame, _ in self.pending:
                candidate = payload_size + 2 + len(frame)
                if candidate > self.max_plaintext:
                    break
                payload_size = candidate
                count += 1
            if count == 0:
                raise ValueError("encoded talkback AAC frame exceeds UDP payload limit")
            if count == 1 and len(self.pending) == 1:
                if current - self.pending[0][1] < self.max_delay:
                    break
            batches.append([frame for frame, _ in self.pending[:count]])
            del self.pending[:count]
        return batches


class _TalkBridgeReceiver:
    """Receive PCMA from go2rtc's send-only exec over a local Unix socket."""

    def __init__(self, path: str) -> None:
        self.path = path
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.socket.bind(path)
        self.socket.setblocking(False)

    def drain(self, limit: int = 16) -> list[bytes]:
        chunks = []
        for _ in range(limit):
            try:
                chunks.append(self.socket.recv(4096))
            except BlockingIOError:
                break
        return chunks

    def close(self) -> None:
        self.socket.close()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


def _decode_alaw(sample: int) -> int:
    """Decode one G.711 A-law byte to signed 16-bit PCM."""
    value = sample ^ 0x55
    magnitude = (value & 0x0F) << 4
    segment = (value & 0x70) >> 4
    if segment == 0:
        magnitude += 8
    elif segment == 1:
        magnitude += 0x108
    else:
        magnitude = (magnitude + 0x108) << (segment - 1)
    return magnitude if value & 0x80 else -magnitude


class _TalkLevelMeter:
    """Measure PCMA level without retaining or recording microphone audio."""

    def __init__(self, interval: float = 2.0) -> None:
        self.interval = interval
        self.last_report = time.monotonic()
        self.samples = 0
        self.sum_squares = 0
        self.peak = 0

    def feed(self, data: bytes) -> tuple[int, float, float] | None:
        for encoded in data:
            decoded = _decode_alaw(encoded)
            absolute = abs(decoded)
            self.samples += 1
            self.sum_squares += decoded * decoded
            self.peak = max(self.peak, absolute)
        now = time.monotonic()
        if not self.samples or now - self.last_report < self.interval:
            return None
        rms = math.sqrt(self.sum_squares / self.samples)
        result = (
            self.samples,
            20 * math.log10(max(rms, 1) / 32768),
            20 * math.log10(max(self.peak, 1) / 32768),
        )
        self.last_report = now
        self.samples = 0
        self.sum_squares = 0
        self.peak = 0
        return result


def _talk_bridge_main(path: str) -> None:
    """Forward go2rtc PCMA stdin to the active P2P client's Unix socket."""
    bridge = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    parent_pid = os.getppid()
    try:
        while os.getppid() == parent_pid:
            chunk = sys.stdin.buffer.read(320)
            if not chunk:
                break
            deadline = time.monotonic() + 5
            while True:
                try:
                    bridge.sendto(chunk, path)
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if time.monotonic() >= deadline:
                        raise SystemExit(
                            f"qubo: talkback media socket is unavailable: {path}"
                        )
                    time.sleep(0.1)
    finally:
        bridge.close()


def _encrypt_audio_rtp(
    cipher: AESGCM,
    frames: bytes | list[bytes],
    sequence: int,
    timestamp: int,
) -> bytes:
    """Build one native-shaped encrypted PT97 packet for the speaker."""
    if isinstance(frames, bytes):
        frames = [frames]
    header = struct.pack(
        "!BBHII",
        0x80,
        0x80 | PT_AUDIO,
        sequence & 0xFFFF,
        timestamp & 0xFFFFFFFF,
        # Both directions in the native-app capture use SSRC zero.
        0,
    )
    nonce = bytes(a ^ b for a, b in zip(IV[:8], header[:8])) + IV[8:16]
    payload = _wrap_audio_frames(frames)
    return header + cipher.encrypt(nonce, payload, header)


def _credentials() -> tuple[str, str, str]:
    """Return (access token, refresh token, user uuid) for the cloud API.

    Reads them straight out of Home Assistant's config entry when pointed at
    it, so this script never has to store a credential of its own and Home
    Assistant stays the only thing that refreshes them. Explicit environment
    variables win, for setups that are not running next to Home Assistant.
    """
    access = os.environ.get("QACCESS")
    refresh = os.environ.get("QREFRESH", "")
    user_uuid = os.environ.get("QUUID", "")
    if access and user_uuid:
        return access, refresh, user_uuid

    store = os.environ.get("QSTORE")
    if not store:
        for candidate in (
            "/ha-storage/core.config_entries",
            "/config/.storage/core.config_entries",
        ):
            if os.path.exists(candidate):
                store = candidate
                break
    if not store:
        raise SystemExit("qubo: set QSTORE or QACCESS/QUUID")

    with open(store) as handle:
        entries = json.load(handle)["data"]["entries"]
    for entry in entries:
        if entry.get("domain") != "qubo":
            continue
        data = entry["data"]
        if not data.get("access_token"):
            continue
        return (
            data["access_token"],
            data.get("refresh_token", ""),
            data.get("user_uuid", ""),
        )
    raise SystemExit(f"qubo: no Qubo entry with a token in {store}")


def _default_advert_ip() -> str:
    """Return the address of the default route, as seen from this host."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))  # TEST-NET-1, never actually sent to
        return probe.getsockname()[0]
    finally:
        probe.close()


def _control_frame(msg_type: int, txid: bytes, attrs: bytes) -> bytes:
    """Build one control frame with its trailing HMAC."""
    header = struct.pack("!HH", msg_type, len(attrs) + 24) + MAGIC + txid
    mac = hmac.new(KEY, header + attrs, hashlib.sha1).digest()
    return header + attrs + struct.pack("!HH", 0x0008, 20) + mac


def _check_a() -> bytes:
    """Liveness probe."""
    return _control_frame(
        BIND_REQUEST, os.urandom(12), struct.pack("!HHI", 0x7002, 4, 0)
    )


def _check_b() -> bytes:
    """The "go" signal: claim a username, then set the stream attribute."""
    attrs = struct.pack("!HH", 0x0025, 4) + struct.pack("!I", 0x70)
    attrs += struct.pack("!HHI", 0x0200, 4, 0)
    return _control_frame(BIND_REQUEST, os.urandom(12), attrs)


def _session_body(port: int, advert: str, quality: str, talk: bool) -> dict:
    """Build the cloud signaling request separately for protocol tests."""
    return {
        "aesIV": IV.hex().upper(),
        "aesKey": KEY.hex().upper(),
        "mediaStreams": "both",
        "mobileUUID": os.environ["QMOB"],
        "offerData": json.dumps(
            [
                {
                    "host": f"{advert}:{port}",
                    "protocol": "UDP",
                    "srflx_0": f"{advert}:{port}",
                }
            ]
        ),
        "protocols": "udp",
        "pttEnabled": "true" if talk else "false",
        "sessionId": str(uuid.uuid4()),
        "sourceType": "live",
        "srcDeviceId": os.environ.get(
            "QSOURCE", os.environ.get("QDEVICEID", "")
        ),
        "streamSourceQuality": quality,
    }


def _send_p2p_call(body: dict, headers: dict) -> None:
    """Submit one stream-manager signalling request."""
    path = (
        "/stream-manager/api/v2/sp/%s/unit/%s/device/%s/p2pCall"
        % (os.environ.get("QSP", DEFAULT_SP), os.environ["QUNIT"], os.environ["QDEVICE"])
    )
    request = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        method="POST",
        headers=headers,
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        response.read()


def _refresh_access_token(
    access_token: str,
    refresh_token: str,
    user_uuid: str,
    source_device_id: str,
) -> str:
    """Renew an expired access token using Qubo's long-lived refresh token."""
    path = "/sms/api/v1/sp/%s/users/%s/auth/refresh" % (
        os.environ.get("QSP", DEFAULT_SP),
        user_uuid,
    )
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {access_token}",
        "Subscriber-Key": access_token,
        "User-UUID": user_uuid,
        "Token-Type": "USER",
        "Source-Device-Id": source_device_id,
        "App-Id": AUTH_APP_ID,
        "Source": "Android",
    }
    payload = {
        "accessToken": access_token,
        "refreshToken": refresh_token,
    }
    request = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        method="POST",
        headers=headers,
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.loads(response.read())
    renewed = data.get("accessToken") or data.get("access_token")
    if not renewed:
        raise ValueError("refresh response did not contain an access token")
    return renewed


def _open_session(
    port: int,
    advert: str,
    quality: str,
    headers: dict,
    talk: bool,
    refresh_token: str = "",
    user_uuid: str = "",
) -> None:
    """Ask the cloud to signal a session for this doorbell."""
    body = _session_body(port, advert, quality, talk)
    try:
        _send_p2p_call(body, headers)
    except urllib.error.HTTPError as err:
        if err.code not in (401, 403) or not refresh_token or not user_uuid:
            raise SystemExit(f"qubo: p2pCall rejected ({err.code})") from err
        try:
            renewed = _refresh_access_token(
                headers["Subscriber-Key"],
                refresh_token,
                user_uuid,
                headers.get("Source-Device-Id", ""),
            )
        except (OSError, ValueError, json.JSONDecodeError) as refresh_err:
            raise SystemExit(
                "qubo: access-token refresh failed; re-login required"
            ) from refresh_err
        headers["Subscriber-Key"] = renewed
        headers["Authorization"] = f"Bearer {renewed}"
        sys.stderr.write(
            "qubo: refreshed expired access token; retrying p2pCall\n"
        )
        sys.stderr.flush()
        try:
            _send_p2p_call(body, headers)
        except urllib.error.HTTPError as retry_err:
            raise SystemExit(
                f"qubo: p2pCall rejected after refresh ({retry_err.code})"
            ) from retry_err


def _emit_annexb(out, payload: bytes) -> None:
    """Write one NAL, turning FU-A fragments back into a start code."""
    if not payload:
        return
    nal_type = payload[0] & 0x1F
    if nal_type == 28 and len(payload) >= 2:  # FU-A
        header = payload[1]
        if (header >> 7) & 1:  # first fragment: restore the real NAL header
            out.write(SC + bytes([(payload[0] & 0xE0) | (header & 0x1F)]))
        out.write(payload[2:])
    else:
        out.write(SC + payload)


def main() -> None:
    """Open a P2P session and relay camera media until the run expires."""
    out_path = sys.argv[1] if len(sys.argv) > 1 else "-"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("QPORT", "49700"))
    advert = os.environ.get("QADVERT") or _default_advert_ip()
    quality = os.environ.get("QQUALITY", "low")
    video_fps = float(os.environ.get("QVIDEOFPS", "10"))
    duration = float(os.environ.get("QDUR", "60"))
    audio_enabled = _env_bool("QAUDIO", True)
    audio_wait = float(os.environ.get("QAUDIOWAIT", "8"))
    audio_gain_db = max(
        -30.0,
        min(30.0, float(os.environ.get("QAUDIOGAINDB", "20"))),
    )
    talk_enabled = _env_bool("QTALK", False)
    talk_gain_db = max(
        -30.0,
        min(30.0, float(os.environ.get("QTALKGAINDB", "12"))),
    )
    ffmpeg = os.environ.get("QFFMPEG", "ffmpeg")
    talk_socket = os.environ.get(
        "QTALKSOCKET", f"/tmp/qubo_talkback_{port}.sock"
    )

    for name in ("QDEVICE", "QUNIT", "QMOB"):
        _require(name)

    access_token, refresh_token, user_uuid = _credentials()
    headers = {
        "Subscriber-Key": access_token,
        "Authorization": f"Bearer {access_token}",
        "User-UUID": user_uuid,
        "Token-Type": "USER",
        "Source-Device-Id": os.environ.get("QSOURCE", os.environ.get("QDEVICEID", "")),
        "App-Id": APP_ID,
        "Source": "Android",
        "Content-Type": "application/json",
    }

    _open_session(
        port,
        advert,
        quality,
        headers,
        talk_enabled,
        refresh_token,
        user_uuid,
    )

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # SO_REUSEADDR lets a fresh run take the port even if a previous process is
    # still lingering, so a restart does not need the port to be free.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as err:
        sys.stderr.write(f"qubo: bind :{port} failed ({err}), retrying in 3s\n")
        time.sleep(3)
        sock.bind(("0.0.0.0", port))
    sock.settimeout(0.05 if talk_enabled else 0.5)

    cipher = AESGCM(KEY)
    output = _MediaOutput(
        out_path,
        audio_enabled,
        audio_wait,
        ffmpeg,
        video_fps,
        audio_gain_db,
    )
    talkback = None
    talk_receiver = None
    if talk_enabled:
        try:
            talkback = _TalkbackEncoder(ffmpeg, talk_gain_db)
            talk_receiver = _TalkBridgeReceiver(talk_socket)
            sys.stderr.write(
                "qubo: experimental talkback enabled "
                f"(PCMA {talk_socket} -> {talk_gain_db:+g} dB limited AAC PT97)\n"
            )
            sys.stderr.flush()
        except (OSError, subprocess.SubprocessError) as err:
            if talkback is not None:
                talkback.close()
                talkback = None
            sys.stderr.write(f"qubo: talkback encoder unavailable ({err})\n")
            sys.stderr.flush()

    doorbell = None
    last_a = last_b = 0.0
    video_order = _OrderedPackets()
    audio_order = _OrderedPackets()
    packets = 0
    video_packets = 0
    audio_packets = 0
    talk_packets = 0
    talk_frames = 0
    talk_level = _TalkLevelMeter()
    talk_packetizer = _TalkbackPacketizer()
    talk_sequence = int.from_bytes(os.urandom(2), "big")
    talk_timestamp = int.from_bytes(os.urandom(4), "big")
    started = time.time()
    last_media = started
    parent_pid = os.getppid()

    features = ["video", "listen-audio" if audio_enabled else "video-only"]
    if talk_enabled:
        features.append("talkback-experimental")
    sys.stderr.write(
        f"qubo: advertising {advert}:{port} -> {out_path} ({', '.join(features)})\n"
    )
    sys.stderr.flush()

    while time.time() - started < duration:
        now = time.time()
        output.tick()
        if os.getppid() != parent_pid:
            # The process that started us is gone, so nobody is reading our
            # output any more. Leaving would hold the UDP port and answer
            # the doorbell's checks for the rest of QDUR.
            sys.stderr.write("qubo: parent gone, exiting\n")
            break
        # A session that never delivers media is dead, not slow. Without
        # this the client would sit in recvfrom for the whole of QDUR,
        # holding the UDP port and answering the doorbell's checks long
        # after go2rtc gave up on it -- which makes the next session fail
        # too.
        if packets == 0 and now - started > MEDIA_TIMEOUT:
            sys.stderr.write(f"qubo: no media within {MEDIA_TIMEOUT:.0f}s, giving up\n")
            break
        if packets and now - last_media > STALL_TIMEOUT:
            sys.stderr.write(f"qubo: media stopped for {STALL_TIMEOUT:.0f}s, giving up\n")
            break
        if doorbell:
            if now - last_a > CHECK_INTERVAL:
                last_a = now
                sock.sendto(_check_a(), doorbell)
            if now - last_b > CHECK_INTERVAL:
                last_b = now
                sock.sendto(_check_b(), doorbell)
            if talkback is not None and talk_receiver is not None:
                chunks = talk_receiver.drain()
                for chunk in chunks:
                    if level := talk_level.feed(chunk):
                        samples, rms_dbfs, peak_dbfs = level
                        sys.stderr.write(
                            "qubo: talkback microphone level "
                            f"samples={samples} rms={rms_dbfs:.1f} dBFS "
                            f"peak={peak_dbfs:.1f} dBFS\n"
                        )
                        sys.stderr.flush()
                    talkback.feed(chunk)
                talk_packetizer.add(talkback.drain())
                for frames in talk_packetizer.drain():
                    packet = _encrypt_audio_rtp(
                        cipher,
                        frames,
                        talk_sequence,
                        talk_timestamp,
                    )
                    sock.sendto(packet, doorbell)
                    if talk_packets == 0:
                        sys.stderr.write(
                            "qubo: talkback media flowing as native-shaped encrypted PT97 "
                            "(M=1, SSRC=0, multi-AU)\n"
                        )
                        sys.stderr.flush()
                    talk_sequence = (talk_sequence + 1) & 0xFFFF
                    talk_timestamp = (
                        talk_timestamp + TALK_AUDIO_SAMPLES * len(frames)
                    ) & 0xFFFFFFFF
                    talk_packets += 1
                    talk_frames += len(frames)
                    if talk_packets % 50 == 0:
                        sys.stderr.write(
                            "qubo: talkback sent "
                            f"{talk_packets} encrypted packets / {talk_frames} AAC frames\n"
                        )
                        sys.stderr.flush()
        try:
            packet, addr = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break

        if len(packet) >= 20 and packet[4:8] == MAGIC:
            # A control frame: remember the doorbell and answer its request.
            doorbell = addr
            if struct.unpack("!H", packet[:2])[0] == BIND_REQUEST:
                sock.sendto(_control_frame(BIND_SUCCESS, packet[8:20], b""), addr)
            continue

        if len(packet) < 12 + 17 or (packet[0] & 0xC0) != 0x80:
            continue
        rtp = packet[:12]
        payload_type = rtp[1] & 0x7F
        if payload_type not in (PT_VIDEO, PT_AUDIO):
            continue

        # The GCM nonce mixes our IV with the RTP header, so the same IV is
        # never reused across packets.
        nonce = bytes(a ^ b for a, b in zip(IV[:8], rtp[:8])) + IV[8:16]
        try:
            body = cipher.decrypt(nonce, packet[12:], rtp)
        except Exception:  # noqa: BLE001 - a corrupt packet is not fatal
            continue
        packets += 1
        last_media = time.time()
        seq = struct.unpack("!H", rtp[2:4])[0]
        try:
            if payload_type == PT_VIDEO:
                video_packets += 1
                video_order.push(seq, body, lambda item: _emit_annexb(output, item))
                output.flush()
            else:
                audio_packets += 1
                audio_order.push(seq, body, output.write_audio)
        except (BrokenPipeError, OSError):
            break

    if talkback is not None:
        talkback.close()
    if talk_receiver is not None:
        talk_receiver.close()
    output.close()
    sock.close()
    sys.stderr.write(
        "qubo: decrypted "
        f"{packets} packets (video={video_packets}, audio={audio_packets}); "
        f"sent talk={talk_packets} packets/{talk_frames} frames; wrote {out_path}\n"
    )
    sys.stderr.flush()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--talk-bridge":
        _talk_bridge_main(sys.argv[2])
    else:
        main()
