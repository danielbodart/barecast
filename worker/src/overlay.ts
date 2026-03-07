/**
 * OverlayRenderer — SVG overlay for browser-side cursor and draw-path rendering.
 *
 * Uses an SVG element positioned over the video with viewBox matching the native
 * video resolution. Cursor positions and draw paths arrive in native pixel
 * coordinates and map directly to SVG coordinates — no manual scaling needed.
 *
 * Cursor shape: Bibata Original left_ptr (GPL-3.0, https://github.com/ful1e5/Bibata_Cursor)
 */

import { VIEWER_COLORS } from "./input";

// Bibata Original left_ptr path data (256x256 viewBox)
// Tip at approximately (62.5, 34.1) in SVG space
const CURSOR_PATH =
    "M76.6287 46.6308L62.4993 34.144L62.5 53.0003L62.5058 208L62.5066 229.287L77.1681 213.855L122.261 166.392L188.193 164.895L209.894 164.403L193.629 150.028L76.6287 46.6308Z";
const CURSOR_TIP_X = 62.5;
const CURSOR_TIP_Y = 34.1;

// Wire protocol message types (must match src/input_protocol.zig)
const MSG_MOUSE_MOVE = 0x01;
const MSG_DRAW_START = 0x10;
const MSG_DRAW_MOVE = 0x11;
const MSG_DRAW_END = 0x12;
const MSG_DRAW_UNDO = 0x13;
const MSG_DRAW_CLEAR = 0x14;

const SVG_NS = "http://www.w3.org/2000/svg";

interface ViewerState {
    cursorX: number;
    cursorY: number;
    cursorVisible: boolean;
    paths: Array<Array<[number, number]>>;
    currentPath: Array<[number, number]> | null;
    cursorEl: SVGGElement | null;
    pathEls: SVGPathElement[];
    currentPathEl: SVGPathElement | null;
}

export class OverlayRenderer {
    private svg: SVGSVGElement;
    private video: HTMLVideoElement;
    private viewers = new Map<number, ViewerState>();
    private localColorIndex = -1;
    private cursorSize = 24; // native pixels
    private rafId: number | null = null;
    private dirty = false;
    private resizeObserver: ResizeObserver;

    constructor(video: HTMLVideoElement) {
        this.video = video;

        this.svg = document.createElementNS(SVG_NS, "svg");
        this.svg.style.position = "absolute";
        this.svg.style.top = "0";
        this.svg.style.left = "0";
        this.svg.style.width = "100%";
        this.svg.style.height = "100%";
        this.svg.style.pointerEvents = "none";
        this.svg.style.overflow = "hidden";

        // viewBox will be set once we know the native resolution
        this.updateViewBox();

        // Ensure parent is positioned for absolute overlay
        const parent = video.parentElement;
        if (parent) {
            if (getComputedStyle(parent).position === "static") {
                parent.style.position = "relative";
            }
            parent.appendChild(this.svg);
        }

        this.resizeObserver = new ResizeObserver(() => this.updateViewBox());
        this.resizeObserver.observe(video);
    }

    private updateViewBox(): void {
        const w = this.video.videoWidth;
        const h = this.video.videoHeight;
        if (w > 0 && h > 0) {
            this.svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
            this.svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
        }
    }

    setLocalColorIndex(index: number): void {
        this.localColorIndex = index;
    }

    private getOrCreateViewer(colorIndex: number): ViewerState {
        let state = this.viewers.get(colorIndex);
        if (!state) {
            state = {
                cursorX: 0,
                cursorY: 0,
                cursorVisible: false,
                paths: [],
                currentPath: null,
                cursorEl: null,
                pathEls: [],
                currentPathEl: null,
            };
            this.viewers.set(colorIndex, state);
        }
        return state;
    }

    handleRelayedMessage(colorIndex: number, payload: Uint8Array): void {
        if (payload.length < 1) return;
        const msgType = payload[0];

        const state = this.getOrCreateViewer(colorIndex);

        switch (msgType) {
            case MSG_MOUSE_MOVE: {
                if (payload.length < 5) return;
                const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
                state.cursorX = view.getUint16(1, true);
                state.cursorY = view.getUint16(3, true);
                state.cursorVisible = true;
                this.dirty = true;
                break;
            }
            case MSG_DRAW_START: {
                if (payload.length < 5) return;
                const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
                const x = view.getUint16(1, true);
                const y = view.getUint16(3, true);
                state.currentPath = [[x, y]];
                this.dirty = true;
                break;
            }
            case MSG_DRAW_MOVE: {
                if (payload.length < 5) return;
                const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
                const x = view.getUint16(1, true);
                const y = view.getUint16(3, true);
                if (state.currentPath) {
                    if (state.currentPath.length < 512) {
                        state.currentPath.push([x, y]);
                    }
                    this.dirty = true;
                }
                break;
            }
            case MSG_DRAW_END: {
                if (state.currentPath && state.currentPath.length > 1) {
                    if (state.paths.length < 64) {
                        state.paths.push(state.currentPath);
                    }
                }
                state.currentPath = null;
                this.dirty = true;
                break;
            }
            case MSG_DRAW_UNDO: {
                if (state.paths.length > 0) {
                    state.paths.pop();
                    this.dirty = true;
                }
                break;
            }
            case MSG_DRAW_CLEAR: {
                state.paths = [];
                state.currentPath = null;
                this.dirty = true;
                break;
            }
        }
    }

    /** Update local cursor position for SVG cursor rendering. */
    handleLocalCursor(x: number, y: number): void {
        if (this.localColorIndex < 0) return;
        const state = this.getOrCreateViewer(this.localColorIndex);
        state.cursorX = x;
        state.cursorY = y;
        state.cursorVisible = true;
        this.dirty = true;
    }

    /** Handle local draw events for instant self-path rendering. */
    handleLocalDraw(
        event: "start" | "move" | "end" | "undo" | "clear",
        x?: number,
        y?: number,
    ): void {
        const state = this.getOrCreateViewer(this.localColorIndex);
        switch (event) {
            case "start":
                if (x !== undefined && y !== undefined) {
                    state.currentPath = [[x, y]];
                    this.dirty = true;
                }
                break;
            case "move":
                if (x !== undefined && y !== undefined && state.currentPath) {
                    if (state.currentPath.length < 512) {
                        state.currentPath.push([x, y]);
                    }
                    this.dirty = true;
                }
                break;
            case "end":
                if (state.currentPath && state.currentPath.length > 1) {
                    if (state.paths.length < 64) {
                        state.paths.push(state.currentPath);
                    }
                }
                state.currentPath = null;
                this.dirty = true;
                break;
            case "undo":
                if (state.paths.length > 0) {
                    state.paths.pop();
                    this.dirty = true;
                }
                break;
            case "clear":
                state.paths = [];
                state.currentPath = null;
                this.dirty = true;
                break;
        }
    }

    removeViewer(colorIndex: number): void {
        const state = this.viewers.get(colorIndex);
        if (state) {
            if (state.cursorEl) state.cursorEl.remove();
            for (const el of state.pathEls) el.remove();
            if (state.currentPathEl) state.currentPathEl.remove();
            this.viewers.delete(colorIndex);
        }
    }

    start(): void {
        if (this.rafId !== null) return;
        const loop = () => {
            this.updateViewBox();
            if (this.dirty) {
                this.render();
                this.dirty = false;
            }
            this.rafId = requestAnimationFrame(loop);
        };
        this.rafId = requestAnimationFrame(loop);
    }

    stop(): void {
        if (this.rafId !== null) {
            cancelAnimationFrame(this.rafId);
            this.rafId = null;
        }
    }

    destroy(): void {
        this.stop();
        this.resizeObserver.disconnect();
        this.svg.remove();
        this.viewers.clear();
    }

    private render(): void {
        for (const [colorIndex, state] of this.viewers) {
            const color = VIEWER_COLORS[colorIndex % VIEWER_COLORS.length];
            const isLocal = colorIndex === this.localColorIndex;

            // Cursor
            if (state.cursorVisible) {
                if (!state.cursorEl) {
                    state.cursorEl = this.createCursorElement(color);
                    this.svg.appendChild(state.cursorEl);
                }
                const scale = this.cursorSize / 256;
                state.cursorEl.setAttribute(
                    "transform",
                    `translate(${state.cursorX}, ${state.cursorY}) scale(${scale}) translate(${-CURSOR_TIP_X}, ${-CURSOR_TIP_Y})`,
                );
            }

            // Draw paths — rebuild if count changed
            this.renderPaths(state, color);
        }
    }

    private renderPaths(state: ViewerState, color: string): void {
        // Completed paths — sync DOM elements with state
        while (state.pathEls.length > state.paths.length) {
            const el = state.pathEls.pop()!;
            el.remove();
        }
        for (let i = 0; i < state.paths.length; i++) {
            if (i >= state.pathEls.length) {
                const el = this.createPathElement(color);
                state.pathEls.push(el);
                this.svg.appendChild(el);
            }
            const d = this.pointsToPathD(state.paths[i]);
            if (state.pathEls[i].getAttribute("d") !== d) {
                state.pathEls[i].setAttribute("d", d);
            }
        }

        // Current in-progress path
        if (state.currentPath && state.currentPath.length >= 2) {
            if (!state.currentPathEl) {
                state.currentPathEl = this.createPathElement(color);
                this.svg.appendChild(state.currentPathEl);
            }
            state.currentPathEl.setAttribute("d", this.pointsToPathD(state.currentPath));
        } else if (state.currentPathEl) {
            state.currentPathEl.remove();
            state.currentPathEl = null;
        }
    }

    private createCursorElement(color: string): SVGGElement {
        const g = document.createElementNS(SVG_NS, "g");
        const path = document.createElementNS(SVG_NS, "path");
        path.setAttribute("d", CURSOR_PATH);
        path.setAttribute("fill", color);
        path.setAttribute("stroke", "#FFFFFF");
        path.setAttribute("stroke-width", "17");
        g.appendChild(path);
        return g;
    }

    private createPathElement(color: string): SVGPathElement {
        const path = document.createElementNS(SVG_NS, "path");
        path.setAttribute("fill", "none");
        path.setAttribute("stroke", color);
        path.setAttribute("stroke-opacity", "0.8");
        path.setAttribute("stroke-width", "2.5");
        path.setAttribute("stroke-linecap", "round");
        path.setAttribute("stroke-linejoin", "round");
        return path;
    }

    private pointsToPathD(points: Array<[number, number]>): string {
        if (points.length < 2) return "";
        let d = `M${points[0][0]} ${points[0][1]}`;
        for (let i = 1; i < points.length; i++) {
            d += `L${points[i][0]} ${points[i][1]}`;
        }
        return d;
    }
}
