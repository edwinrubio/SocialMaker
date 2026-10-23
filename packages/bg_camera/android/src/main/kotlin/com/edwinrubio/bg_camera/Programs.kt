package com.edwinrubio.bg_camera

import android.opengl.GLES20
import java.nio.FloatBuffer

/**
 * Shaders. Texture units: 0 = camera (external OES), 1 = mask, 2 = background,
 * 3 = blur source.
 */
class Programs {
    val passthrough = Program(PASSTHROUGH_FRAGMENT)
    val compositeImage = Program(composite("sampler2D"))
    val compositeVideo = Program(composite("samplerExternalOES"))

    /** One pass of a separable Gaussian blur; set [Program.texelStep] per direction. */
    val blur = Program(BLUR_FRAGMENT)

    class Program(
        fragmentSource: String,
    ) {
        private val id = link(VERTEX, fragmentSource)
        private val position = GLES20.glGetAttribLocation(id, "aPosition")
        private val texCoord = GLES20.glGetAttribLocation(id, "aTexCoord")
        private val cameraScaleLocation = GLES20.glGetUniformLocation(id, "uCameraScale")
        private val cameraMatrixLocation = GLES20.glGetUniformLocation(id, "uCameraMatrix")
        private val backgroundScaleLocation = GLES20.glGetUniformLocation(id, "uBackgroundScale")
        private val backgroundMatrixLocation = GLES20.glGetUniformLocation(id, "uBackgroundMatrix")
        private val texelStepLocation = GLES20.glGetUniformLocation(id, "uTexelStep")

        var backgroundScale = floatArrayOf(1f, 1f)
        var texelStep = floatArrayOf(0f, 0f)

        fun use(
            quad: FloatBuffer,
            cameraScale: FloatArray,
            cameraMatrix: FloatArray,
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
            GLES20.glUniformMatrix4fv(cameraMatrixLocation, 1, false, cameraMatrix, 0)
            GLES20.glUniform2fv(backgroundScaleLocation, 1, backgroundScale, 0)
            GLES20.glUniformMatrix4fv(backgroundMatrixLocation, 1, false, backgroundMatrix, 0)
            GLES20.glUniform2fv(texelStepLocation, 1, texelStep, 0)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(id, "uCamera"), 0)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(id, "uMask"), 1)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(id, "uBackground"), 2)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(id, "uSource"), 3)
        }
    }

    private companion object {
        const val VERTEX = """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            uniform vec2 uCameraScale;
            uniform mat4 uCameraMatrix;
            uniform vec2 uBackgroundScale;
            uniform mat4 uBackgroundMatrix;
            varying vec2 vCameraUv;
            varying vec2 vMaskUv;
            varying vec2 vBackgroundUv;
            void main() {
                gl_Position = aPosition;
                // Upright (portrait, mirrored for selfie) coordinates; the mask is upright too.
                vMaskUv = (aTexCoord - 0.5) * uCameraScale + 0.5;
                // The camera texture is in sensor orientation.
                vCameraUv = (uCameraMatrix * vec4(vMaskUv, 0.0, 1.0)).xy;
                vec2 backgroundUv = (aTexCoord - 0.5) * uBackgroundScale + 0.5;
                vBackgroundUv = (uBackgroundMatrix * vec4(backgroundUv, 0.0, 1.0)).xy;
            }
        """

        const val PASSTHROUGH_FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vCameraUv;
            uniform samplerExternalOES uCamera;
            void main() {
                gl_FragColor = texture2D(uCamera, vCameraUv);
            }
        """

        // Soft threshold on the person confidence avoids a hard, flickering edge.
        fun composite(backgroundSampler: String) =
            """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vCameraUv;
            varying vec2 vMaskUv;
            varying vec2 vBackgroundUv;
            uniform samplerExternalOES uCamera;
            uniform sampler2D uMask;
            uniform $backgroundSampler uBackground;
            void main() {
                float person = smoothstep(0.3, 0.7, texture2D(uMask, vMaskUv).r);
                vec4 camera = texture2D(uCamera, vCameraUv);
                vec4 background = texture2D(uBackground, vBackgroundUv);
                gl_FragColor = mix(background, camera, person);
            }
            """

        // 9-tap Gaussian; the source is a framebuffer texture (bottom-left origin).
        const val BLUR_FRAGMENT = """
            precision mediump float;
            varying vec2 vMaskUv;
            uniform sampler2D uSource;
            uniform vec2 uTexelStep;
            void main() {
                vec2 uv = vec2(vMaskUv.x, 1.0 - vMaskUv.y);
                vec4 sum = texture2D(uSource, uv) * 0.2270270270;
                sum += texture2D(uSource, uv + uTexelStep * 1.3846153846) * 0.3162162162;
                sum += texture2D(uSource, uv - uTexelStep * 1.3846153846) * 0.3162162162;
                sum += texture2D(uSource, uv + uTexelStep * 3.2307692308) * 0.0702702703;
                sum += texture2D(uSource, uv - uTexelStep * 3.2307692308) * 0.0702702703;
                gl_FragColor = sum;
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
            // #extension must be the first statement, so drop the raw-string indent.
            GLES20.glShaderSource(shader, source.trimIndent())
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE) { "Shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}" }
            return shader
        }
    }
}
