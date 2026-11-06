import importlib.util
import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import unittest
import urllib.error
from unittest import mock
from pathlib import Path


CLIENT_PATH = Path(__file__).with_name("qubo_p2p_client.py")
SPEC = importlib.util.spec_from_file_location("qubo_p2p_client", CLIENT_PATH)
client = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(client)


def adts_frame(payload: bytes, frequency_index: int = 8, channels: int = 1) -> bytes:
    """Build a small AAC-LC ADTS frame; index 8 is 16 kHz."""
    length = 7 + len(payload)
    profile = 1  # AAC-LC stores object type minus one.
    header = bytes(
        [
            0xFF,
            0xF1,
            (profile << 6) | (frequency_index << 2) | (channels >> 2),
            ((channels & 0x03) << 6) | ((length >> 11) & 0x03),
            (length >> 3) & 0xFF,
            ((length & 0x07) << 5) | 0x1F,
            0xFC,
        ]
    )
    return header + payload


class AudioProtocolTest(unittest.TestCase):
    def test_adts_validation_accepts_single_and_multiple_frames(self):
        first = adts_frame(b"one")
        second = adts_frame(b"two-two")

        self.assertEqual(client._adts_frame_length(first), len(first))
        self.assertTrue(client._is_adts(first))
        self.assertTrue(client._is_adts(first + second))
        self.assertFalse(client._is_adts(first[:-1]))
        self.assertFalse(client._is_adts(b"not-aac"))

    def test_observed_mpeg4_au_header_unwraps_adts(self):
        # The live capture started 00 10 09 48 ff f1... 0x0948 >> 3 is a
        # 297-byte access unit, matching a seven-byte ADTS header + 290 bytes.
        frame = adts_frame(bytes(290))
        wrapped = bytes.fromhex("00100948") + frame
        audio, had_header = client._unwrap_audio_payload(wrapped)
        self.assertEqual(len(frame), 297)
        self.assertTrue(had_header)
        self.assertEqual(audio, frame)
        self.assertEqual(client._wrap_audio_payload(frame), wrapped)

    def test_talkback_packet_round_trips_through_aes_gcm(self):
        key = bytes(range(16))
        original_iv = client.IV
        client.IV = bytes(range(16, 32))
        try:
            cipher = client.AESGCM(key)
            frame = adts_frame(b"speaker-audio")
            packet = client._encrypt_audio_rtp(
                cipher,
                frame,
                sequence=0x1234,
                timestamp=0x10203040,
            )
            header = packet[:12]
            self.assertEqual(header[0], 0x80)
            self.assertEqual(header[1] & 0x7F, client.PT_AUDIO)
            self.assertTrue(header[1] & 0x80)
            self.assertEqual(struct.unpack("!H", header[2:4])[0], 0x1234)
            self.assertEqual(struct.unpack("!I", header[8:12])[0], 0)
            nonce = bytes(
                a ^ b for a, b in zip(client.IV[:8], header[:8])
            ) + client.IV[8:16]
            self.assertEqual(
                cipher.decrypt(nonce, packet[12:], header),
                client._wrap_audio_payload(frame),
            )
        finally:
            client.IV = original_iv

    def test_native_multi_au_talkback_packet_shape(self):
        first = adts_frame(b"first")
        second = adts_frame(b"second")
        wrapped = client._wrap_audio_frames([first, second])

        self.assertEqual(struct.unpack("!H", wrapped[:2])[0], 32)
        self.assertEqual(struct.unpack("!H", wrapped[2:4])[0] >> 3, len(first))
        self.assertEqual(struct.unpack("!H", wrapped[4:6])[0] >> 3, len(second))
        self.assertEqual(wrapped[6:], first + second)

    def test_talkback_packetizer_batches_frames_and_respects_mtu(self):
        packetizer = client._TalkbackPacketizer(
            max_udp_payload=100,
            max_delay=0.18,
        )
        frames = [adts_frame(bytes(20)) for _ in range(5)]
        packetizer.add(frames, now=1.0)

        batches = packetizer.drain(now=1.0)

        self.assertEqual([len(batch) for batch in batches], [2, 2])
        self.assertEqual(len(packetizer.pending), 1)
        self.assertEqual(packetizer.drain(now=1.17), [])
        self.assertEqual(len(packetizer.drain(now=1.19)[0]), 1)

    def test_talk_flag_is_sent_in_p2p_signaling(self):
        old_mobile = os.environ.get("QMOB")
        old_source = os.environ.get("QSOURCE")
        os.environ["QMOB"] = "mobile-1"
        os.environ["QSOURCE"] = "source-1"
        try:
            body = client._session_body(49700, "192.168.1.10", "high", True)
            self.assertEqual(body["mediaStreams"], "both")
            self.assertEqual(body["pttEnabled"], "true")
            self.assertEqual(body["mobileUUID"], "mobile-1")
            self.assertEqual(body["srcDeviceId"], "source-1")
            offer = json.loads(body["offerData"])[0]
            self.assertEqual(offer["host"], "192.168.1.10:49700")
        finally:
            if old_mobile is None:
                os.environ.pop("QMOB", None)
            else:
                os.environ["QMOB"] = old_mobile
            if old_source is None:
                os.environ.pop("QSOURCE", None)
            else:
                os.environ["QSOURCE"] = old_source

    def test_expired_p2p_token_is_refreshed_and_retried(self):
        headers = {
            "Subscriber-Key": "expired-access",
            "Source-Device-Id": "login-device",
        }
        rejected = urllib.error.HTTPError(
            "https://example.test/p2pCall",
            401,
            "Unauthorized",
            {},
            None,
        )
        with (
            mock.patch.object(
                client,
                "_session_body",
                return_value={"sessionId": "session-1"},
            ),
            mock.patch.object(
                client,
                "_send_p2p_call",
                side_effect=[rejected, None],
            ) as send,
            mock.patch.object(
                client,
                "_refresh_access_token",
                return_value="renewed-access",
            ) as refresh,
        ):
            client._open_session(
                49700,
                "192.168.1.10",
                "high",
                headers,
                True,
                "refresh-token",
                "user-uuid",
            )

        refresh.assert_called_once_with(
            "expired-access",
            "refresh-token",
            "user-uuid",
            "login-device",
        )
        self.assertEqual(send.call_count, 2)
        self.assertEqual(headers["Subscriber-Key"], "renewed-access")
        self.assertEqual(headers["Authorization"], "Bearer renewed-access")

    def test_video_and_audio_use_independent_wrapping_sequence_spaces(self):
        emitted = []
        packets = client._OrderedPackets()
        packets.push(0xFFFF, b"last", emitted.append)
        packets.push(0, b"first", emitted.append)
        self.assertEqual(emitted, [b"last", b"first"])

    def test_reorder_buffer_recovers_from_a_large_packet_gap(self):
        emitted = []
        packets = client._OrderedPackets()
        packets.push(100, b"before-gap", emitted.append)
        packets.last_flush -= client.STALL_DROP_SECONDS + 1

        packets.push(110, b"after-gap", emitted.append)

        self.assertEqual(emitted, [b"before-gap", b"after-gap"])
        self.assertEqual(packets.next_seq, 111)

    def test_talk_bridge_receiver_keeps_backchannel_in_same_process(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "talk.sock")
            try:
                receiver = client._TalkBridgeReceiver(path)
            except PermissionError:
                self.skipTest("sandbox does not allow Unix datagram sockets")
            sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            try:
                sender.sendto(b"pcma", path)
                self.assertEqual(receiver.drain(), [b"pcma"])
            finally:
                sender.close()
                receiver.close()
            self.assertFalse(Path(path).exists())

    def test_talk_level_meter_distinguishes_speech_from_alaw_silence(self):
        silence = client._TalkLevelMeter(interval=0)
        speech = client._TalkLevelMeter(interval=0)

        _, silence_rms, silence_peak = silence.feed(bytes([0xD5]) * 320)
        _, speech_rms, speech_peak = speech.feed(bytes([0x00]) * 320)

        self.assertLess(silence_rms, -70)
        self.assertLess(silence_peak, -70)
        self.assertGreater(speech_rms, -20)
        self.assertGreater(speech_peak, -20)
    @unittest.skipUnless(
        shutil.which("ffmpeg") and shutil.which("ffprobe"),
        "requires the go2rtc image's ffmpeg and ffprobe",
    )
    def test_ffmpeg_mux_produces_h264_and_aac_mpegts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            video = root / "video.h264"
            audio = root / "audio.aac"
            combined = root / "combined.ts"
            subprocess.run(
                [
                    "ffmpeg",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-f",
                    "lavfi",
                    "-i",
                    "testsrc2=size=160x90:rate=15",
                    "-t",
                    "1",
                    "-c:v",
                    "libx264",
                    "-preset",
                    "ultrafast",
                    "-tune",
                    "zerolatency",
                    "-f",
                    "h264",
                    str(video),
                ],
                check=True,
            )
            subprocess.run(
                [
                    "ffmpeg",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-f",
                    "lavfi",
                    "-i",
                    "sine=frequency=440:sample_rate=16000",
                    "-t",
                    "1",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "32k",
                    "-f",
                    "adts",
                    str(audio),
                ],
                check=True,
            )

            muxer = client._AvMuxer(
                str(combined),
                "ffmpeg",
                video_fps=15,
                audio_gain_db=20,
            )
            frame_rate_option = muxer.process.args.index("-framerate")
            self.assertEqual(muxer.process.args[frame_rate_option + 1], "15")
            self.assertEqual(
                muxer.process.args.count("-use_wallclock_as_timestamps"),
                2,
            )
            audio_filter_option = muxer.process.args.index("-filter_complex")
            audio_filter = muxer.process.args[audio_filter_option + 1]
            self.assertIn("volume=20dB", audio_filter)
            audio_bytes = audio.read_bytes()
            first_frame_length = client._adts_frame_length(audio_bytes)
            self.assertIsNotNone(first_frame_length)
            # Match live arrival: one AAC frame starts the muxer, then a large
            # video backlog arrives before the rest of the audio. Synchronous
            # pipe writes deadlock here while ffmpeg probes the other input.
            muxer.write_audio(audio_bytes[:first_frame_length])
            muxer.write_video(video.read_bytes())
            muxer.write_audio(audio_bytes[first_frame_length:])
            muxer.close()

            probe = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "stream=codec_name,codec_type",
                    "-of",
                    "json",
                    str(combined),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            streams = json.loads(probe.stdout)["streams"]
            self.assertIn(
                {"codec_name": "h264", "codec_type": "video"},
                streams,
            )
            self.assertTrue(
                any(
                    stream["codec_name"] == "aac"
                    and stream["codec_type"] == "audio"
                    for stream in streams
                )
            )
            self.assertFalse(any(stream["codec_name"] == "opus" for stream in streams))

    @unittest.skipUnless(shutil.which("ffmpeg"), "requires ffmpeg")
    def test_talkback_ffmpeg_encodes_pcma_as_adts_aac(self):
        encoded = subprocess.run(
            client._talkback_ffmpeg_command("ffmpeg", 12),
            input=bytes([0xD5]) * 8000,
            check=True,
            capture_output=True,
        ).stdout
        self.assertTrue(client._is_adts(encoded))

    def test_talkback_gain_is_limited_before_encoding(self):
        command = client._talkback_ffmpeg_command("ffmpeg", 12)
        audio_filter = command[command.index("-af") + 1]

        self.assertIn("level_in=3.981072", audio_filter)
        self.assertIn("limit=0.95", audio_filter)
        self.assertIn("level=false", audio_filter)
        self.assertIn("latency=true", audio_filter)


if __name__ == "__main__":
    unittest.main()
