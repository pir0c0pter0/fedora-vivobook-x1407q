#!/usr/bin/python3
"""Teste offscreen minimo: EGL sobre GBM num render node, GLES2, FBO, um
triangulo com shader, glReadPixels. Nao abre janela nem toca no compositor.
uso: egl-offscreen-test.py [/dev/dri/renderD128] [largura altura]
sai 0 se o renderer e de hardware e os pixels batem; 1 caso contrario."""
import ctypes as C, os, sys

node = sys.argv[1] if len(sys.argv) > 1 else "/dev/dri/renderD128"
W, H = (int(sys.argv[2]), int(sys.argv[3])) if len(sys.argv) > 3 else (1920, 1200)
gbm, egl, gl = C.CDLL("libgbm.so.1"), C.CDLL("libEGL.so.1"), C.CDLL("libGLESv2.so.2")
P = C.c_void_p
gbm.gbm_create_device.restype = P
egl.eglGetPlatformDisplay.restype = P
egl.eglGetPlatformDisplay.argtypes = [C.c_uint, P, P]
egl.eglCreateContext.restype = P
egl.eglCreateContext.argtypes = [P, P, P, P]
egl.eglInitialize.argtypes = [P, P, P]
egl.eglChooseConfig.argtypes = [P, P, P, C.c_int, P]
egl.eglMakeCurrent.argtypes = [P, P, P, P]
egl.eglQueryString.restype = C.c_char_p
egl.eglQueryString.argtypes = [P, C.c_int]
gl.glGetString.restype = C.c_char_p
gl.glClearColor.argtypes = [C.c_float] * 4


def die(msg):
    print("FALHA:", msg, "(egl error 0x%x)" % egl.eglGetError())
    sys.exit(1)


fd = os.open(node, os.O_RDWR | os.O_CLOEXEC)
dev = gbm.gbm_create_device(fd) or die("gbm_create_device")
dpy = egl.eglGetPlatformDisplay(0x31D7, dev, None) or die("eglGetPlatformDisplay")  # EGL_PLATFORM_GBM_KHR
egl.eglInitialize(dpy, None, None) or die("eglInitialize")
print("EGL_VERSION :", egl.eglQueryString(dpy, 0x3054).decode())
egl.eglBindAPI(0x30A0)  # EGL_OPENGL_ES_API
cfg, n = P(), C.c_int()
attrs = (C.c_int * 5)(0x3033, 0, 0x3040, 0x0004, 0x3038)  # SURFACE_TYPE 0, RENDERABLE_TYPE ES2, NONE
(egl.eglChooseConfig(dpy, attrs, C.byref(cfg), 1, C.byref(n)) and n.value) or die("eglChooseConfig")
ctx = egl.eglCreateContext(dpy, cfg, None, (C.c_int * 3)(0x3098, 2, 0x3038)) or die("eglCreateContext")
egl.eglMakeCurrent(dpy, None, None, ctx) or die("eglMakeCurrent (surfaceless)")

renderer = gl.glGetString(0x1F01).decode()
print("GL_RENDERER :", renderer)
print("GL_VERSION  :", gl.glGetString(0x1F02).decode())

tex, fbo = C.c_uint(), C.c_uint()
gl.glGenTextures(1, C.byref(tex))
gl.glBindTexture(0x0DE1, tex)
gl.glTexImage2D(0x0DE1, 0, 0x1908, W, H, 0, 0x1908, 0x1401, None)
gl.glGenFramebuffers(1, C.byref(fbo))
gl.glBindFramebuffer(0x8D40, fbo)
gl.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, tex, 0)
if gl.glCheckFramebufferStatus(0x8D40) != 0x8CD5:
    die("FBO incompleto")


def shader(kind, src):
    s = gl.glCreateShader(kind)
    b = C.c_char_p(src.encode())
    gl.glShaderSource(s, 1, C.byref(b), None)
    gl.glCompileShader(s)
    ok = C.c_int()
    gl.glGetShaderiv(s, 0x8B81, C.byref(ok))
    ok.value or die("compilacao de shader")
    return s


prog = gl.glCreateProgram()
gl.glAttachShader(prog, shader(0x8B31, "attribute vec2 p; void main(){gl_Position=vec4(p,0.,1.);}"))
gl.glAttachShader(prog, shader(0x8B30, "precision mediump float; void main(){gl_FragColor=vec4(0.,1.,0.,1.);}"))
gl.glBindAttribLocation(prog, 0, b"p")
gl.glLinkProgram(prog)
gl.glUseProgram(prog)
gl.glViewport(0, 0, W, H)
gl.glClearColor(1, 0, 0, 1)
gl.glClear(0x4000)
# triangulo verde cobrindo a metade inferior esquerda, sobre fundo vermelho
verts = (C.c_float * 6)(-1, -1, 1, -1, -1, 1)
gl.glVertexAttribPointer(0, 2, 0x1406, 0, 0, verts)
gl.glEnableVertexAttribArray(0)
gl.glDrawArrays(0x0004, 0, 3)
gl.glFinish()


def px(x, y):
    b = (C.c_ubyte * 4)()
    gl.glReadPixels(x, y, 1, 1, 0x1908, 0x1401, b)
    return tuple(b)


inside, outside = px(W // 8, H // 8), px(W - 8, H - 8)
print("pixel dentro do triangulo:", inside, "(esperado 0,255,0,255)")
print("pixel fora  do triangulo:", outside, "(esperado 255,0,0,255)")
print("glGetError: 0x%x" % gl.glGetError())
soft = any(s in renderer.lower() for s in ("llvmpipe", "softpipe", "swrast"))
ok = not soft and inside == (0, 255, 0, 255) and outside == (255, 0, 0, 255)
print("RESULTADO:", "OK" if ok else "FALHA" + (" (renderer de software)" if soft else " (pixels errados)"))
sys.exit(0 if ok else 1)
