const std = @import("std");

// ============================================================================
// GL constants
// ============================================================================

const GL_TEXTURE_2D: c_uint = 0x0DE1;
const GL_UNSIGNED_BYTE: c_uint = 0x1401;
const GL_NEAREST: c_int = 0x2600;
const GL_LINEAR: c_int = 0x2601;
const GL_TEXTURE_MIN_FILTER: c_uint = 0x2801;
const GL_TEXTURE_MAG_FILTER: c_uint = 0x2800;
const GL_TEXTURE_WRAP_S: c_uint = 0x2802;
const GL_TEXTURE_WRAP_T: c_uint = 0x2803;
const GL_CLAMP_TO_EDGE: c_int = 0x812F;
const GL_R8: c_int = 0x8229;
const GL_RG8: c_int = 0x822B;
const GL_RED: c_uint = 0x1903;
const GL_RG: c_uint = 0x8227;
const GL_FRAMEBUFFER: c_uint = 0x8D40;
const GL_COLOR_ATTACHMENT0: c_uint = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: c_uint = 0x8CD5;
const GL_VERTEX_SHADER: c_uint = 0x8B31;
const GL_FRAGMENT_SHADER: c_uint = 0x8B30;
const GL_COMPILE_STATUS: c_uint = 0x8B81;
const GL_LINK_STATUS: c_uint = 0x8B82;
const GL_TRIANGLE_STRIP: c_uint = 0x0005;
const GL_TEXTURE0: c_uint = 0x84C0;

// ============================================================================
// GL function declarations (resolved from libGL.so at link time)
// ============================================================================

extern "c" fn glGenTextures(n: c_int, textures: *c_uint) void;
extern "c" fn glDeleteTextures(n: c_int, textures: *const c_uint) void;
extern "c" fn glBindTexture(target: c_uint, texture: c_uint) void;
extern "c" fn glTexImage2D(target: c_uint, level: c_int, internalformat: c_int, width: c_int, height: c_int, border: c_int, format: c_uint, type_: c_uint, pixels: ?*const anyopaque) void;
extern "c" fn glTexParameteri(target: c_uint, pname: c_uint, param: c_int) void;
extern "c" fn glViewport(x: c_int, y: c_int, width: c_int, height: c_int) void;
extern "c" fn glDrawArrays(mode: c_uint, first: c_int, count: c_int) void;
extern "c" fn glGenFramebuffers(n: c_int, framebuffers: *c_uint) void;
extern "c" fn glDeleteFramebuffers(n: c_int, framebuffers: *const c_uint) void;
extern "c" fn glBindFramebuffer(target: c_uint, framebuffer: c_uint) void;
extern "c" fn glFramebufferTexture2D(target: c_uint, attachment: c_uint, textarget: c_uint, texture: c_uint, level: c_int) void;
extern "c" fn glCheckFramebufferStatus(target: c_uint) c_uint;
extern "c" fn glCreateShader(type_: c_uint) c_uint;
extern "c" fn glDeleteShader(shader: c_uint) void;
extern "c" fn glShaderSource(shader: c_uint, count: c_int, string: *const [*:0]const u8, length: ?*const c_int) void;
extern "c" fn glCompileShader(shader: c_uint) void;
extern "c" fn glGetShaderiv(shader: c_uint, pname: c_uint, params: *c_int) void;
extern "c" fn glGetShaderInfoLog(shader: c_uint, bufSize: c_int, length: *c_int, infoLog: [*]u8) void;
extern "c" fn glCreateProgram() c_uint;
extern "c" fn glDeleteProgram(program: c_uint) void;
extern "c" fn glAttachShader(program: c_uint, shader: c_uint) void;
extern "c" fn glLinkProgram(program: c_uint) void;
extern "c" fn glGetProgramiv(program: c_uint, pname: c_uint, params: *c_int) void;
extern "c" fn glUseProgram(program: c_uint) void;
extern "c" fn glGetUniformLocation(program: c_uint, name: [*:0]const u8) c_int;
extern "c" fn glUniform1i(location: c_int, v0: c_int) void;
extern "c" fn glGenVertexArrays(n: c_int, arrays: *c_uint) void;
extern "c" fn glDeleteVertexArrays(n: c_int, arrays: *const c_uint) void;
extern "c" fn glBindVertexArray(array: c_uint) void;
extern "c" fn glActiveTexture(texture: c_uint) void;
extern "c" fn glFinish() void;

// ============================================================================
// Shader sources — BT.709 limited range (matches gpu-screen-recorder)
// ============================================================================

const vertex_src: [*:0]const u8 =
    \\#version 330 core
    \\out vec2 texcoord;
    \\void main() {
    \\    float x = float(gl_VertexID & 1);
    \\    float y = float(gl_VertexID >> 1);
    \\    texcoord = vec2(x, y);
    \\    gl_Position = vec4(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

// NvFBC BGRA byte order — .bgr swizzle gives (R, G, B).
const y_fragment_src: [*:0]const u8 =
    \\#version 330 core
    \\in vec2 texcoord;
    \\uniform sampler2D tex;
    \\out float FragColor;
    \\void main() {
    \\    vec3 rgb = texture(tex, texcoord).bgr;
    \\    FragColor = 0.180353 * rgb.r + 0.609765 * rgb.g + 0.060118 * rgb.b + 0.062745;
    \\}
;

const uv_fragment_src: [*:0]const u8 =
    \\#version 330 core
    \\in vec2 texcoord;
    \\uniform sampler2D tex;
    \\out vec2 FragColor;
    \\void main() {
    \\    vec3 rgb = texture(tex, texcoord).bgr;
    \\    FragColor = vec2(
    \\        -0.096964 * rgb.r - 0.327830 * rgb.g + 0.429412 * rgb.b + 0.500000,
    \\         0.429412 * rgb.r - 0.385927 * rgb.g - 0.038049 * rgb.b + 0.500000
    \\    );
    \\}
;

// ============================================================================
// ColorConversion
// ============================================================================

pub const ColorConversion = struct {
    y_texture: c_uint,
    uv_texture: c_uint,
    y_fbo: c_uint,
    uv_fbo: c_uint,
    y_program: c_uint,
    uv_program: c_uint,
    vao: c_uint,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) !ColorConversion {
        var y_tex: c_uint = 0;
        glGenTextures(1, &y_tex);
        glBindTexture(GL_TEXTURE_2D, y_tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, @intCast(width), @intCast(height), 0, GL_RED, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        const uv_width = (width + 1) / 2;
        const uv_height = (height + 1) / 2;
        var uv_tex: c_uint = 0;
        glGenTextures(1, &uv_tex);
        glBindTexture(GL_TEXTURE_2D, uv_tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RG8, @intCast(uv_width), @intCast(uv_height), 0, GL_RG, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        var y_fbo: c_uint = 0;
        glGenFramebuffers(1, &y_fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, y_fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, y_tex, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            std.debug.print("ColorConversion: Y FBO incomplete\n", .{});
            return error.ColorConversionInitFailed;
        }

        var uv_fbo: c_uint = 0;
        glGenFramebuffers(1, &uv_fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, uv_fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, uv_tex, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            std.debug.print("ColorConversion: UV FBO incomplete\n", .{});
            return error.ColorConversionInitFailed;
        }

        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        const y_program = try compileProgram(vertex_src, y_fragment_src, "Y");
        errdefer glDeleteProgram(y_program);
        const uv_program = try compileProgram(vertex_src, uv_fragment_src, "UV");
        errdefer glDeleteProgram(uv_program);

        glUseProgram(y_program);
        glUniform1i(glGetUniformLocation(y_program, "tex"), 0);
        glUseProgram(uv_program);
        glUniform1i(glGetUniformLocation(uv_program, "tex"), 0);
        glUseProgram(0);

        var vao: c_uint = 0;
        glGenVertexArrays(1, &vao);

        std.debug.print("ColorConversion: initialized BT.709 limited BGRA→NV12, {}x{}\n", .{ width, height });

        return .{
            .y_texture = y_tex, .uv_texture = uv_tex,
            .y_fbo = y_fbo, .uv_fbo = uv_fbo,
            .y_program = y_program, .uv_program = uv_program,
            .vao = vao, .width = width, .height = height,
        };
    }

    pub fn convert(self: *const ColorConversion, source_texture: u32) void {
        glBindVertexArray(self.vao);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, source_texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        glBindFramebuffer(GL_FRAMEBUFFER, self.y_fbo);
        glViewport(0, 0, @intCast(self.width), @intCast(self.height));
        glUseProgram(self.y_program);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        glBindFramebuffer(GL_FRAMEBUFFER, self.uv_fbo);
        glViewport(0, 0, @intCast((self.width + 1) / 2), @intCast((self.height + 1) / 2));
        glUseProgram(self.uv_program);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        glFinish();
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glUseProgram(0);
        glBindVertexArray(0);
    }

    pub fn deinit(self: *ColorConversion) void {
        glDeleteProgram(self.y_program);
        glDeleteProgram(self.uv_program);
        glDeleteVertexArrays(1, &self.vao);
        glDeleteFramebuffers(1, &self.y_fbo);
        glDeleteFramebuffers(1, &self.uv_fbo);
        glDeleteTextures(1, &self.y_texture);
        glDeleteTextures(1, &self.uv_texture);
    }
};

fn compileShader(type_: c_uint, source: [*:0]const u8, label: []const u8) !c_uint {
    const shader = glCreateShader(type_);
    if (shader == 0) return error.ColorConversionInitFailed;
    glShaderSource(shader, 1, &source, null);
    glCompileShader(shader);
    var status: c_int = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var log_buf: [512]u8 = undefined;
        var log_len: c_int = 0;
        glGetShaderInfoLog(shader, 512, &log_len, &log_buf);
        std.debug.print("ColorConversion: {s} shader compile error: {s}\n", .{ label, log_buf[0..@intCast(log_len)] });
        glDeleteShader(shader);
        return error.ColorConversionInitFailed;
    }
    return shader;
}

fn compileProgram(vert_src: [*:0]const u8, frag_src: [*:0]const u8, label: []const u8) !c_uint {
    const vert = try compileShader(GL_VERTEX_SHADER, vert_src, label);
    defer glDeleteShader(vert);
    const frag = try compileShader(GL_FRAGMENT_SHADER, frag_src, label);
    defer glDeleteShader(frag);
    const program = glCreateProgram();
    if (program == 0) return error.ColorConversionInitFailed;
    glAttachShader(program, vert);
    glAttachShader(program, frag);
    glLinkProgram(program);
    var status: c_int = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status == 0) {
        std.debug.print("ColorConversion: {s} program link failed\n", .{label});
        glDeleteProgram(program);
        return error.ColorConversionInitFailed;
    }
    return program;
}
