package com.edwinrubio.bg_camera

import android.opengl.GLES20
import java.nio.FloatBuffer

/**
 * Shaders for the three render modes. Texture units: 0 = camera, 1 = mask,
 * 2 = background.
 */
class Programs {
    val passthrough = Program(PASSTHROUGH_FRAGMENT)
    val compositeImage = Program(COMPOSITE_FRAGMENT.replace("BACKGROUND_SAMPLER", "sampler2D"))
    val compositeVideo =
        Program(
            "#extension GL_OES_EGL_image_external : require\n" +
                COMPOSITE_FRAGMENT.replace("BACKGROUND_SAMPLER", "samplerExternalOES"),
        )

    class Program(
        fragmentSource: String,
    ) {
        private val id = link(VERTEX, fragmentSource)
        private val position = GLES20.glGetAttribLocation(id, "aPosition")
        private val texCoord = GLES20.glGetAttribLocation(id, "aTexCoord")
        private val cameraScaleLocation = GLES20.glGetUniformLocation(id, "uCameraScale")
        private val backgroundScaleLocation = GLES20.glGetUniformLocation(id, "uBackgroundScale")
        private val backgroundMatrixLocation = GLES20.glGetUniformLocation(id, "uBackgroundMatrix")

        var backgroundScale = floatArrayOf(1f, 1f)

        fun use(
            quad: FloatBuffer,
            cameraScale: FloatArray,
            backgroundMatrix: FloatArray,
        ) {
            GLES20.glUseProgram(id)
            quad.position(0)
            GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glEnableVertexAttribArray(position)
            quad.position(2)
            GLES20.glVertexAttribPointer(texCoord, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glEnableVertexAttribArray(texCoord)

            GLES20.glUniform2fv(cameraScaleLocation, 1, cameraScale, 0)
            GLES20.glUniform2fv(backgroundScaleLocation, 1, backgroundScale, 0)
            GLES20.glUniformMatrix4fv(backgroundMatrixLocation, 1, false, backgroundMatrix, 0)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(id, "uCamera"), 0)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(id, "uMask"), 1)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(id, "uBackground"), 2)
        }
    }

    private companion object {
        const val VERTEX = """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            uniform vec2 uCameraScale;
            uniform vec2 uBackgroundScale;
            uniform mat4 uBackgroundMatrix;
            varying vec2 vCameraUv;
            varying vec2 vBackgroundUv;
            void main() {
                gl_Position = aPosition;
                vCameraUv = (aTexCoord - 0.5) * uCameraScale + 0.5;
                vec2 backgroundUv = (aTexCoord - 0.5) * uBackgroundScale + 0.5;
                vBackgroundUv = (uBackgroundMatrix * vec4(backgroundUv, 0.0, 1.0)).xy;
            }
        """

        const val PASSTHROUGH_FRAGMENT = """
            precision mediump float;
            varying vec2 vCameraUv;
            varying vec2 vBackgroundUv;
            uniform sampler2D uCamera;
            void main() {
                gl_FragColor = texture2D(uCamera, vCameraUv);
            }
        """

        // Soft threshold on the person confidence avoids a hard, flickering edge.
        const val COMPOSITE_FRAGMENT = """
            precision mediump float;
            varying vec2 vCameraUv;
            varying vec2 vBackgroundUv;
            uniform sampler2D uCamera;
            uniform sampler2D uMask;
            uniform BACKGROUND_SAMPLER uBackground;
            void main() {
                float person = smoothstep(0.3, 0.7, texture2D(uMask, vCameraUv).r);
                vec4 camera = texture2D(uCamera, vCameraUv);
                vec4 background = texture2D(uBackground, vBackgroundUv);
                gl_FragColor = mix(background, camera, person);
            }
        """

        fun link(
            vertexSource: String,
            fragmentSource: String,
        ): Int {
            val program = GLES20.glCreateProgram()
            GLES20.glAttachShader(program, compile(GLES20.GL_VERTEX_SHADER, vertexSource))
            GLES20.glAttachShader(program, compile(GLES20.GL_FRAGMENT_SHADER, fragmentSource))
            GLES20.glLinkProgram(program)
            val status = IntArray(1)
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE) { "Program link failed: ${GLES20.glGetProgramInfoLog(program)}" }
            return program
        }

        fun compile(
            type: Int,
            source: String,
        ): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE) { "Shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}" }
            return shader
        }
    }
}
