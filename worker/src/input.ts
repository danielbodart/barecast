/**
 * InputController — captures browser events, encodes binary protocol,
 * sends over WebRTC data channel.
 *
 * Two modes:
 * - Input (default): mouse moves host cursor, keyboard types
 * - Draw: left-drag draws, right-click undoes, long-press right clears
 */

import type { OverlayRenderer } from "./overlay";

export type ViewerMode = "draw" | "input";

// Wire protocol message types (must match src/input_protocol.zig)
const MSG_MOUSE_MOVE = 0x01;
const MSG_MOUSE_DOWN = 0x02;
const MSG_MOUSE_UP = 0x03;
const MSG_SCROLL = 0x04;
const MSG_KEY_DOWN = 0x05;
const MSG_KEY_UP = 0x06;
const MSG_DRAW_START = 0x10;
const MSG_DRAW_MOVE = 0x11;
const MSG_DRAW_END = 0x12;
const MSG_DRAW_UNDO = 0x13;
const MSG_DRAW_CLEAR = 0x14;
const MSG_APP_RESIZE = 0x20;
const MSG_HOST_RESIZE = 0x21;
const MSG_VIEWER_LEFT = 0xfd;
const MSG_RELAY = 0xfe;
const MSG_COLOR_ASSIGN = 0xff;

// Long-press threshold for right-click clear (ms)
const LONG_PRESS_MS = 500;

export class InputController {
    private dc: RTCDataChannel;
    private video: HTMLVideoElement;
    private mode: ViewerMode = "input";
    private colorIndex: number = -1;
    private drawing = false;
    private rightPressTimer: ReturnType<typeof setTimeout> | null = null;
    private onModeChange: ((mode: ViewerMode) => void) | null = null;
    private onColorAssign: ((index: number) => void) | null = null;
    private overlay: OverlayRenderer | null = null;
    private resizeObserver: ResizeObserver | null = null;
    private resizeTimer: ReturnType<typeof setTimeout> | null = null;
    private hostResizeTimer: ReturnType<typeof setTimeout> | null = null;

    // Native video resolution (for coordinate mapping)
    private nativeW = 0;
    private nativeH = 0;

    constructor(
        dc: RTCDataChannel,
        video: HTMLVideoElement,
        opts?: {
            onModeChange?: (mode: ViewerMode) => void;
            onColorAssign?: (index: number) => void;
            overlay?: OverlayRenderer;
        },
    ) {
        this.dc = dc;
        this.video = video;
        this.onModeChange = opts?.onModeChange ?? null;
        this.onColorAssign = opts?.onColorAssign ?? null;
        this.overlay = opts?.overlay ?? null;

        dc.binaryType = "arraybuffer";
        dc.onmessage = (e) => this.handleHostMessage(e);

        this.bindEvents();

        // Send resize when the video element changes size (debounced)
        this.resizeObserver = new ResizeObserver(() => {
            if (this.resizeTimer) clearTimeout(this.resizeTimer);
            this.resizeTimer = setTimeout(() => {
                const rect = this.video.getBoundingClientRect();
                const w = Math.round(rect.width * devicePixelRatio);
                const h = Math.round(rect.height * devicePixelRatio);
                // Skip if matching native video resolution (avoids resize loop)
                if (w === this.video.videoWidth && h === this.video.videoHeight) return;
                if (w > 0 && h > 0) this.sendResize(w, h);
            }, 250);
        });
        this.resizeObserver.observe(this.video);
    }

    get currentMode(): ViewerMode {
        return this.mode;
    }

    toggleMode(): void {
        const was = this.mode;
        this.mode = was === "draw" ? "input" : "draw";
        // End any in-progress drawing when switching modes
        if (this.drawing) {
            this.send1(MSG_DRAW_END);
            this.drawing = false;
        }
        // Clear all drawings when entering input mode
        if (was === "draw" && this.mode === "input") {
            this.send1(MSG_DRAW_CLEAR);
            this.overlay?.handleLocalDraw("clear");
        }
        this.onModeChange?.(this.mode);
    }

    destroy(): void {
        this.unbindEvents();
        if (this.resizeObserver) {
            this.resizeObserver.disconnect();
            this.resizeObserver = null;
        }
        if (this.resizeTimer) {
            clearTimeout(this.resizeTimer);
            this.resizeTimer = null;
        }
        if (this.hostResizeTimer) {
            clearTimeout(this.hostResizeTimer);
            this.hostResizeTimer = null;
        }
    }

    // ── Coordinate mapping ──────────────────────────────────────────────

    private updateNativeRes(): void {
        if (this.video.videoWidth > 0) {
            this.nativeW = this.video.videoWidth;
            this.nativeH = this.video.videoHeight;
        }
    }

    /** Map viewport mouse coordinates to native video resolution. */
    private mapCoords(
        clientX: number,
        clientY: number,
    ): { x: number; y: number } | null {
        this.updateNativeRes();
        if (this.nativeW === 0 || this.nativeH === 0) return null;

        const rect = this.video.getBoundingClientRect();
        // Video might be letterboxed — compute the actual video area within the element
        const videoAspect = this.nativeW / this.nativeH;
        const elemAspect = rect.width / rect.height;

        let videoX: number, videoY: number, videoW: number, videoH: number;

        if (elemAspect > videoAspect) {
            // Letterboxed horizontally (pillarboxed)
            videoH = rect.height;
            videoW = videoH * videoAspect;
            videoX = rect.left + (rect.width - videoW) / 2;
            videoY = rect.top;
        } else {
            // Letterboxed vertically
            videoW = rect.width;
            videoH = videoW / videoAspect;
            videoX = rect.left;
            videoY = rect.top + (rect.height - videoH) / 2;
        }

        const relX = (clientX - videoX) / videoW;
        const relY = (clientY - videoY) / videoH;

        if (relX < 0 || relX > 1 || relY < 0 || relY > 1) return null;

        return {
            x: Math.round(relX * (this.nativeW - 1)),
            y: Math.round(relY * (this.nativeH - 1)),
        };
    }

    // ── Event binding ───────────────────────────────────────────────────

    private _onMouseMove = (e: MouseEvent) => this.onMouseMove(e);
    private _onMouseDown = (e: MouseEvent) => this.onMouseDown(e);
    private _onMouseUp = (e: MouseEvent) => this.onMouseUp(e);
    private _onWheel = (e: WheelEvent) => this.onWheel(e);
    private _onKeyDown = (e: KeyboardEvent) => this.onKeyDown(e);
    private _onKeyUp = (e: KeyboardEvent) => this.onKeyUp(e);
    private _onContextMenu = (e: Event) => e.preventDefault();
    private _onMouseEnter = () => this.overlay?.fadeIn();
    private _onMouseLeave = () => this.overlay?.fadeOut();

    private bindEvents(): void {
        const el = this.video;
        el.addEventListener("mousemove", this._onMouseMove);
        el.addEventListener("mousedown", this._onMouseDown);
        el.addEventListener("mouseup", this._onMouseUp);
        el.addEventListener("wheel", this._onWheel, { passive: false });
        el.addEventListener("contextmenu", this._onContextMenu);
        el.addEventListener("mouseenter", this._onMouseEnter);
        el.addEventListener("mouseleave", this._onMouseLeave);
        // Keyboard events on document (video may not be focusable in all states)
        document.addEventListener("keydown", this._onKeyDown);
        document.addEventListener("keyup", this._onKeyUp);
    }

    private unbindEvents(): void {
        const el = this.video;
        el.removeEventListener("mousemove", this._onMouseMove);
        el.removeEventListener("mousedown", this._onMouseDown);
        el.removeEventListener("mouseup", this._onMouseUp);
        el.removeEventListener("wheel", this._onWheel);
        el.removeEventListener("contextmenu", this._onContextMenu);
        el.removeEventListener("mouseenter", this._onMouseEnter);
        el.removeEventListener("mouseleave", this._onMouseLeave);
        document.removeEventListener("keydown", this._onKeyDown);
        document.removeEventListener("keyup", this._onKeyUp);
    }

    // ── Mouse events ────────────────────────────────────────────────────

    private onMouseMove(e: MouseEvent): void {
        const pt = this.mapCoords(e.clientX, e.clientY);
        if (!pt) return;

        // Always send cursor position and update local overlay cursor
        this.sendXY(MSG_MOUSE_MOVE, pt.x, pt.y);
        this.overlay?.handleLocalCursor(pt.x, pt.y);

        if (this.mode === "draw" && this.drawing) {
            this.sendXY(MSG_DRAW_MOVE, pt.x, pt.y);
            this.overlay?.handleLocalDraw("move", pt.x, pt.y);
        }
    }

    private onMouseDown(e: MouseEvent): void {
        const pt = this.mapCoords(e.clientX, e.clientY);
        if (!pt) return;

        if (this.mode === "draw") {
            if (e.button === 0) {
                // Left click — start drawing
                this.drawing = true;
                this.sendXY(MSG_DRAW_START, pt.x, pt.y);
                this.overlay?.handleLocalDraw("start", pt.x, pt.y);
            } else if (e.button === 2) {
                // Right click — undo (immediate), clear (long press)
                this.rightPressTimer = setTimeout(() => {
                    this.send1(MSG_DRAW_CLEAR);
                    this.overlay?.handleLocalDraw("clear");
                    this.rightPressTimer = null;
                }, LONG_PRESS_MS);
            }
        } else {
            this.sendMouseButton(MSG_MOUSE_DOWN, pt.x, pt.y, e.button);
        }
    }

    private onMouseUp(e: MouseEvent): void {
        const pt = this.mapCoords(e.clientX, e.clientY);

        if (this.mode === "draw") {
            if (e.button === 0 && this.drawing) {
                this.drawing = false;
                this.send1(MSG_DRAW_END);
                this.overlay?.handleLocalDraw("end");
            } else if (e.button === 2) {
                if (this.rightPressTimer) {
                    // Short right-click — undo
                    clearTimeout(this.rightPressTimer);
                    this.rightPressTimer = null;
                    this.send1(MSG_DRAW_UNDO);
                    this.overlay?.handleLocalDraw("undo");
                }
            }
        } else if (pt) {
            this.sendMouseButton(MSG_MOUSE_UP, pt.x, pt.y, e.button);
        }
    }

    private onWheel(e: WheelEvent): void {
        if (this.mode !== "input") return;
        e.preventDefault();
        const pt = this.mapCoords(e.clientX, e.clientY);
        if (!pt) return;

        // deltaY: positive = scroll down, negative = scroll up
        // Normalize to ±120 per notch (standard)
        const delta = Math.round(
            -e.deltaY * (e.deltaMode === 1 ? 120 : e.deltaMode === 2 ? 120 : 1),
        );
        this.sendScroll(pt.x, pt.y, delta);
    }

    // ── Keyboard events ─────────────────────────────────────────────────

    private onKeyDown(e: KeyboardEvent): void {
        if (e.repeat) return;

        if (this.mode === "input") {
            e.preventDefault();
            this.sendKey(MSG_KEY_DOWN, e.code);
        }
    }

    private onKeyUp(e: KeyboardEvent): void {
        if (e.code === "Escape") return;

        if (this.mode === "input") {
            e.preventDefault();
            this.sendKey(MSG_KEY_UP, e.code);
        }
    }

    // ── Host → viewer messages ──────────────────────────────────────────

    private handleHostMessage(e: MessageEvent): void {
        if (!(e.data instanceof ArrayBuffer)) return;
        const data = new Uint8Array(e.data);
        if (data.length < 1) return;

        if (data[0] === MSG_COLOR_ASSIGN && data.length >= 2) {
            this.colorIndex = data[1];
            this.onColorAssign?.(this.colorIndex);
            this.overlay?.setLocalColorIndex(this.colorIndex);
        } else if (data[0] === MSG_RELAY && data.length >= 3) {
            const colorIndex = data[1];
            this.overlay?.handleRelayedMessage(colorIndex, data.subarray(2));
        } else if (data[0] === MSG_HOST_RESIZE && data.length >= 5) {
            const view = new DataView(e.data as ArrayBuffer);
            const w = view.getUint16(1, true);
            const h = view.getUint16(3, true);
            this.handleHostResize(w, h);
        } else if (data[0] === MSG_VIEWER_LEFT && data.length >= 2) {
            this.overlay?.removeViewer(data[1]);
        }
    }

    // ── Binary encoding ─────────────────────────────────────────────────

    private send(buf: ArrayBuffer): void {
        if (this.dc.readyState === "open") {
            this.dc.send(buf);
        }
    }

    /** 1-byte message (draw_end, draw_undo, draw_clear). */
    private send1(type: number): void {
        this.send(new Uint8Array([type]).buffer);
    }

    /** [type] [u16 x] [u16 y] = 5 bytes */
    private sendXY(type: number, px: number, py: number): void {
        const buf = new ArrayBuffer(5);
        const view = new DataView(buf);
        view.setUint8(0, type);
        view.setUint16(1, px, true);
        view.setUint16(3, py, true);
        this.send(buf);
    }

    /** [0x20] [u16 width] [u16 height] = 5 bytes */
    private sendResize(width: number, height: number): void {
        this.sendXY(MSG_APP_RESIZE, Math.min(width, 65535), Math.min(height, 65535));
    }

    /** Handle host_resize broadcast — resize this viewer's window to match. */
    private handleHostResize(width: number, height: number): void {
        // Suppress echo: if this matches the current video resolution, ignore
        if (width === this.video.videoWidth && height === this.video.videoHeight) return;

        if (this.hostResizeTimer) clearTimeout(this.hostResizeTimer);
        this.hostResizeTimer = setTimeout(() => {
            this.hostResizeTimer = null;
            // Re-check after debounce — stream may have caught up
            if (width === this.video.videoWidth && height === this.video.videoHeight) return;

            // Update CSS custom props for zoom mode
            document.documentElement.style.setProperty("--video-w", width + "px");
            document.documentElement.style.setProperty("--video-h", height + "px");

            const chromW = window.outerWidth - window.innerWidth;
            const chromH = window.outerHeight - window.innerHeight;
            const ratio = width / height;
            const maxW = screen.availWidth;
            const maxH = screen.availHeight;
            let fitW = width + chromW;
            let fitH = height + chromH;
            if (fitW > maxW) {
                fitW = maxW;
                fitH = Math.round((maxW - chromW) / ratio) + chromH;
            }
            if (fitH > maxH) {
                fitH = maxH;
                fitW = Math.round((maxH - chromH) * ratio) + chromW;
            }
            window.resizeTo(fitW, fitH);
        }, 250);
    }

    /** [type] [u16 x] [u16 y] [u8 button] = 6 bytes */
    private sendMouseButton(
        type: number,
        px: number,
        py: number,
        button: number,
    ): void {
        const buf = new ArrayBuffer(6);
        const view = new DataView(buf);
        view.setUint8(0, type);
        view.setUint16(1, px, true);
        view.setUint16(3, py, true);
        view.setUint8(5, button);
        this.send(buf);
    }

    /** [type] [u16 x] [u16 y] [i16 delta] = 7 bytes */
    private sendScroll(px: number, py: number, delta: number): void {
        const buf = new ArrayBuffer(7);
        const view = new DataView(buf);
        view.setUint8(0, MSG_SCROLL);
        view.setUint16(1, px, true);
        view.setUint16(3, py, true);
        view.setInt16(5, Math.max(-32768, Math.min(32767, delta)), true);
        this.send(buf);
    }

    /** [type] [u8 len] [code bytes] = 2+N bytes */
    private sendKey(type: number, code: string): void {
        const encoded = new TextEncoder().encode(code);
        if (encoded.length > 255) return;
        const buf = new Uint8Array(2 + encoded.length);
        buf[0] = type;
        buf[1] = encoded.length;
        buf.set(encoded, 2);
        this.send(buf.buffer);
    }
}

// Viewer color hex values (must match src/viewer_state.zig)
export const VIEWER_COLORS = [
    "#4DB0FF", // blue
    "#FF6666", // red
    "#66DE66", // green
    "#FFBF33", // yellow
    "#CC73FF", // purple
    "#FF8C33", // orange
    "#66E6D9", // cyan
    "#FF80B3", // pink
];
