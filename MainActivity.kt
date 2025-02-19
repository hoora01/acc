package com.example.accelerometerdisplacement

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import kotlin.math.pow

class MainActivity : AppCompatActivity(), SensorEventListener {

    private lateinit var sensorManager: SensorManager
    private var accelerometer: Sensor? = null
    private lateinit var displacementTextView: TextView

    private var lastUpdateTime: Long = 0
    private var lastX: Float = 0f
    private var lastY: Float = 0f
    private var lastZ: Float = 0f
    private var velocityX: Float = 0f
    private var velocityY: Float = 0f
    private var velocityZ: Float = 0f
    private var displacementX: Float = 0f
    private var displacementY: Float = 0f
    private var displacementZ: Float = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        displacementTextView = findViewById(R.id.displacementTextView)

        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    }

    override fun onResume() {
        super.onResume()
        accelerometer?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
    }

    override fun onPause() {
        super.onPause()
        sensorManager.unregisterListener(this)
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) {
            val currentTime = System.currentTimeMillis()
            
            if (lastUpdateTime != 0L) {
                val timeInterval = (currentTime - lastUpdateTime) / 1000f // Convert to seconds

                val x = event.values[0]
                val y = event.values[1]
                val z = event.values[2]

                // Calculate velocity (integrate acceleration)
                velocityX += (x + lastX) / 2 * timeInterval
                velocityY += (y + lastY) / 2 * timeInterval
                velocityZ += (z + lastZ) / 2 * timeInterval

                // Calculate displacement (integrate velocity)
                displacementX += velocityX * timeInterval
                displacementY += velocityY * timeInterval
                displacementZ += velocityZ * timeInterval

                // Convert displacement to mm
                val displacementXmm = displacementX * 1000
                val displacementYmm = displacementY * 1000
                val displacementZmm = displacementZ * 1000

                // Calculate total displacement
                val totalDisplacement = Math.sqrt(
                    displacementXmm.pow(2) + displacementYmm.pow(2) + displacementZmm.pow(2)
                ).toFloat()

                // Update UI
                displacementTextView.text = String.format(
                    "Displacement:\nX: %.2f mm\nY: %.2f mm\nZ: %.2f mm\nTotal: %.2f mm",
                    displacementXmm, displacementYmm, displacementZmm, totalDisplacement
                )
            }

            lastUpdateTime = currentTime
            lastX = event.values[0]
            lastY = event.values[1]
            lastZ = event.values[2]
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Not used in this example
    }
}

