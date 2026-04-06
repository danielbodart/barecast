GL_RENDERBUFFER — Not Hallucinated, But Format-Restricted

  The docs do list GL_RENDERBUFFER as a valid target. Here are the actual sources:

  CUDA Driver API (docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__GL.html):
  > "target... must be one of GL_TEXTURE_2D, GL_TEXTURE_RECTANGLE, GL_TEXTURE_CUBE_MAP, GL_TEXTURE_3D, GL_TEXTURE_2D_ARRAY, or GL_RENDERBUFFER"

  The reason it failed wasn't the target — it was the internal format. The docs list a specific supported format table: {GL_R, GL_RG, GL_RGBA} × {8, 16, 16F,
  32F, 8UI, 16UI, 32UI, 8I, 16I, 32I}. wlroots' renderbuffer is backed by a GBM BO via EGLImage — its internal format may not match what CUDA expects. NVIDIA
  engineer Simon_Green confirmed in this 2009 forum thread
  (https://forums.developer.nvidia.com/t/cugraphicsglregisterimage-returns-cuda-error-invalid-value-cugraphicsglregisterimage-cuda-3-0/13495):

  > "we currently only support floating point and unnormalized integer texture formats for CUDA/OpenGL texture interop. Try using GL_RGBA8UI_EXT instead of
  GL_RGBA8."

  So GL_RENDERBUFFER is valid syntactically, but renderbuffers created via glEGLImageTargetRenderbufferStorageOES (the wlroots path) likely have an internal
  format that CUDA can't handle — whereas our GL_TEXTURE_2D created with explicit glTexStorage2D(GL_RGBA8) works because we control the format exactly.

  This could be worth revisiting later — if we create the renderbuffer with GL_RGBA32F or GL_RGBA8UI instead, it might work. But the FBO blit approach is
  already fast (200us) and clean.

  Additional forum threads:
  - https://forums.developer.nvidia.com/t/cudagraphicsglregisterimage-for-renderbuffer/16771
  - https://forums.developer.nvidia.com/t/cudagraphicsglregisterimage-failed-cudaerrornotsupported-error/76317
