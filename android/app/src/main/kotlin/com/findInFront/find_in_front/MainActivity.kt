package com.findInFront.find_in_front

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

class MainActivity : FlutterActivity() {

    private var volumeEventSink: EventChannel.EventSink? = null
    private val tone = ToneEngine()
    private val audioExec = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Volume button stream → Flutter
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "find_in_front/volume_buttons"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                volumeEventSink = events
            }
            override fun onCancel(arguments: Any?) {
                volumeEventSink = null
            }
        })

        // Spatial proximity beep: synthesized sine tone with distance→pitch and
        // azimuth→stereo-pan. Args: freq (Hz), pan (-1 left .. 1 right), ms, gain.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "find_in_front/beep"
        ).setMethodCallHandler { call, result ->
            if (call.method == "beep") {
                val freq = (call.argument<Int>("freq")) ?: 800
                val pan  = (call.argument<Double>("pan")) ?: 0.0
                val ms   = (call.argument<Int>("ms")) ?: 80
                val gain = (call.argument<Double>("gain")) ?: 0.7
                audioExec.execute {
                    try { tone.play(freq, pan.toFloat(), ms, gain.toFloat()) } catch (_: Exception) {}
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> { volumeEventSink?.success("up"); true }
            KeyEvent.KEYCODE_VOLUME_DOWN -> { volumeEventSink?.success("down"); true }
            else -> super.onKeyDown(keyCode, event)
        }
    }

    override fun onDestroy() {
        tone.release()
        audioExec.shutdownNow()
        super.onDestroy()
    }
}

/**
 * Generates short stereo sine beeps on a persistent AudioTrack.
 * Pan: -1 = full left, 0 = centre, +1 = full right (constant-side gain).
 * A 5 ms attack/release envelope prevents clicks.
 */
private class ToneEngine {
    private val sampleRate = 44100
    private var track: AudioTrack? = null

    private fun ensure() {
        if (track != null) return
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val t = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(minBuf * 2)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                AudioManager.STREAM_MUSIC, sampleRate,
                AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2, AudioTrack.MODE_STREAM
            )
        }
        t.play()
        track = t
    }

    fun play(freq: Int, pan: Float, ms: Int, gain: Float) {
        ensure()
        val t = track ?: return
        val n = sampleRate * ms / 1000
        val buf = ShortArray(n * 2)
        val leftGain  = if (pan <= 0f) 1f else 1f - pan
        val rightGain = if (pan >= 0f) 1f else 1f + pan
        val attack = (sampleRate * 0.005f)
        for (i in 0 until n) {
            val s = sin(2.0 * PI * freq * i / sampleRate).toFloat()
            val env = min(1f, min(i.toFloat(), (n - i).toFloat()) / attack)
            val v = s * env * gain * Short.MAX_VALUE
            buf[2 * i]     = (v * leftGain).toInt().toShort()
            buf[2 * i + 1] = (v * rightGain).toInt().toShort()
        }
        t.write(buf, 0, buf.size)
    }

    fun release() {
        try { track?.stop(); track?.release() } catch (_: Exception) {}
        track = null
    }
}
