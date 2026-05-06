/**
 * FluidEngine — WebGL implementation EXACTLY mirroring the Resona App's Metal shader.
 * Converts snoise(float2) and double domain warping perfectly to WebGL.
 */const VERT = `
  attribute vec2 a_position;
  varying vec2 v_uv;
  void main() {
      v_uv = a_position * 0.5 + 0.5;
      v_uv.y = 1.0 - v_uv.y;
      gl_Position = vec4(a_position, 0.0, 1.0);
  }
`;

const FRAG = `
  precision highp float;
  varying vec2 v_uv;
  
  uniform float u_time;
  uniform float u_speed;
  uniform vec2 u_resolution;
  
  uniform vec4 u_color0;
  uniform vec4 u_color1;
  uniform vec4 u_color2;
  uniform vec4 u_color3;
  uniform vec4 u_color4;

  vec3 mod289(vec3 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
  vec2 mod289(vec2 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
  vec3 permute(vec3 x) { return mod289(((x*34.0)+1.0)*x); }

  float snoise(vec2 v) {
      const vec4 C = vec4(0.211324865405187, 0.366025403784439,
                          -0.577350269189626, 0.024390243902439);
      vec2 i = floor(v + dot(v, C.yy));
      vec2 x0 = v - i + dot(i, C.xx);
      vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
      vec4 x12 = x0.xyxy + C.xxzz;
      x12.xy -= i1;
      i = mod289(i);
      vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));
      vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
      m = m*m; m = m*m;
      vec3 x_ = 2.0*fract(p * C.www) - 1.0;
      vec3 h = abs(x_) - 0.5;
      vec3 ox = floor(x_ + 0.5);
      vec3 a0 = x_ - ox;
      m *= 1.79284291400159 - 0.85373472095314*(a0*a0 + h*h);
      vec3 g;
      g.x = a0.x*x0.x + h.x*x0.y;
      g.yz = a0.yz*x12.xz + h.yz*x12.yw;
      return 130.0 * dot(m, g);
  }

  void main() {
      vec2 uv = v_uv;
      float t = u_time * u_speed;

      float aspect = u_resolution.x / u_resolution.y;
      vec2 st = vec2(uv.x * aspect, uv.y);

      vec2 warp1 = vec2(
          snoise(st * 1.2 + vec2(t*0.3, t*0.2)),
          snoise(st * 1.2 + vec2(t*0.2, -t*0.3))
      ) * 0.18;

      vec2 warp2 = vec2(
          snoise((st + warp1) * 0.8 + vec2(-t*0.15, t*0.1)),
          snoise((st + warp1) * 0.8 + vec2(t*0.1, t*0.15))
      ) * 0.12;

      vec2 warped = st + warp1 + warp2;

      float n1 = snoise(warped * 1.5  + vec2(t*0.4,  t*0.25));
      float n2 = snoise(warped * 2.2  + vec2(-t*0.3, t*0.4));
      float n3 = snoise(warped * 1.0  + vec2(t*0.2, -t*0.35));
      float n4 = snoise(warped * 2.8  + vec2(-t*0.2, -t*0.15));

      vec4 c = u_color0;
      c = mix(c, u_color1, smoothstep(-0.4, 0.4, n1));
      c = mix(c, u_color2, smoothstep(-0.3, 0.5, n2) * 0.7);
      c = mix(c, u_color3, smoothstep(-0.5, 0.3, n3) * 0.55);
      c = mix(c, u_color4, smoothstep(-0.35, 0.35, n4) * 0.4);

      float n5 = snoise((warped + warp2*2.0) * 1.8 + vec2(t*0.35, t*0.15));
      c = mix(c, u_color1*0.6 + u_color3*0.4, smoothstep(-0.2, 0.5, n5) * 0.3);

      vec2 vc = uv - 0.5;
      float vig = 1.0 - dot(vc, vc) * 0.65;
      c.rgb *= vig;

      c.rgb *= 0.72;

      // Dithering: breaks up 8-bit color boundaries to eliminate banding
      float dither = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453);
      c.rgb += (dither / 255.0) - (0.5 / 255.0);

      gl_FragColor = vec4(c.rgb, 1.0);
  }
`;

function rgbToHslBoost(r, g, b) {
  let max = Math.max(r, g, b), min = Math.min(r, g, b);
  let h, s, l = (max + min) / 2;
  if (max === min) {
    h = s = 0;
  } else {
    let d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    switch (max) {
      case r: h = (g - b) / d + (g < b ? 6 : 0); break;
      case g: h = (b - r) / d + 2; break;
      case b: h = (r - g) / d + 4; break;
    }
    h /= 6;
  }
  s = Math.min(s * 1.2, 1.0);
  let r1, g1, b1;
  if (s === 0) {
    r1 = g1 = b1 = l;
  } else {
    const hue2rgb = (p, q, t) => {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1/6) return p + (q - p) * 6 * t;
      if (t < 1/2) return q;
      if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
      return p;
    };
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    let p = 2 * l - q;
    r1 = hue2rgb(p, q, h + 1/3);
    g1 = hue2rgb(p, q, h);
    b1 = hue2rgb(p, q, h - 1/3);
  }
  return [r1, g1, b1, 1.0];
}

export const PALETTES = {
  graduation: [
    rgbToHslBoost(0.65, 0.35, 0.55),
    rgbToHslBoost(0.25, 0.20, 0.45),
    rgbToHslBoost(0.75, 0.40, 0.60),
    rgbToHslBoost(0.85, 0.65, 0.35),
    rgbToHslBoost(0.45, 0.35, 0.65),
  ],
  starboy: [
    rgbToHslBoost(0.85, 0.15, 0.25), // Bright Red
    rgbToHslBoost(0.15, 0.15, 0.35), // Dark Blue
    rgbToHslBoost(0.95, 0.25, 0.35), // Pinkish Red
    rgbToHslBoost(0.10, 0.10, 0.15), // Almost Black
    rgbToHslBoost(0.20, 0.10, 0.20), // Deep Purple
  ],
  takecare: [
    rgbToHslBoost(0.80, 0.60, 0.20), // Gold
    rgbToHslBoost(0.30, 0.20, 0.10), // Dark Brown
    rgbToHslBoost(0.90, 0.75, 0.40), // Light Gold
    rgbToHslBoost(0.15, 0.10, 0.05), // Very Dark Brown
    rgbToHslBoost(0.50, 0.35, 0.15), // Mid Brown
  ],
  flowerboy: [
    rgbToHslBoost(0.95, 0.65, 0.15), // Sunflower Yellow/Orange
    rgbToHslBoost(0.20, 0.60, 0.30), // Leaf Green
    rgbToHslBoost(0.95, 0.85, 0.25), // Bright Yellow
    rgbToHslBoost(0.40, 0.65, 0.85), // Sky Blue
    rgbToHslBoost(0.85, 0.45, 0.15), // Deep Orange
  ]
};

export default class FluidEngine {
  constructor(canvas, paletteName = 'graduation') {
    this.canvas = canvas;
    this.gl = canvas.getContext('webgl', { alpha: false, antialias: false, depth: false });
    this._intensity = 0.5;
    this._palette = PALETTES[paletteName] || PALETTES.graduation;
    this._targetPalette = this._palette;
    this._startTime = performance.now();
    this._animId = null;
    this._init();
  }

  _init() {
    const gl = this.gl;
    const vs = this._compile(gl.VERTEX_SHADER, VERT);
    const fs = this._compile(gl.FRAGMENT_SHADER, FRAG);
    this.program = gl.createProgram();
    gl.attachShader(this.program, vs);
    gl.attachShader(this.program, fs);
    gl.linkProgram(this.program);
    gl.useProgram(this.program);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.STATIC_DRAW);
    const pos = gl.getAttribLocation(this.program, 'a_position');
    gl.enableVertexAttribArray(pos);
    gl.vertexAttribPointer(pos, 2, gl.FLOAT, false, 0, 0);
    this.u = {
      time:       gl.getUniformLocation(this.program, 'u_time'),
      resolution: gl.getUniformLocation(this.program, 'u_resolution'),
      speed:      gl.getUniformLocation(this.program, 'u_speed'),
      colors: [
        gl.getUniformLocation(this.program, 'u_color0'),
        gl.getUniformLocation(this.program, 'u_color1'),
        gl.getUniformLocation(this.program, 'u_color2'),
        gl.getUniformLocation(this.program, 'u_color3'),
        gl.getUniformLocation(this.program, 'u_color4')
      ]
    };
  }

  _compile(type, src) {
    const gl = this.gl;
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    return s;
  }

  resize() {
    const dpr = Math.min(window.devicePixelRatio, 2) * 0.5;
    const w = Math.floor(this.canvas.clientWidth * dpr);
    const h = Math.floor(this.canvas.clientHeight * dpr);
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
      this.gl.viewport(0, 0, w, h);
    }
  }

  start() {
    if (this._animId) return; // already running

    // Set up observer to only render when on-screen
    if (!this._observer) {
      this._observer = new IntersectionObserver((entries) => {
        this._isVisible = entries[0].isIntersecting;
      }, { threshold: 0 });
      this._observer.observe(this.canvas);
    }

    const gl = this.gl;
    this._isVisible = true; // Assume true until observer fires

    const loop = () => {
      this._animId = requestAnimationFrame(loop);

      if (!this._isVisible) return; // Skip WebGL draw calls if off-screen

      this.resize();
      const t = (performance.now() - this._startTime) / 1000;
      const currentSpeed = 0.02 + (this._intensity * 0.26);
      gl.uniform1f(this.u.time, t);
      gl.uniform1f(this.u.speed, currentSpeed);
      gl.uniform2f(this.u.resolution, this.canvas.width, this.canvas.height);
      
      for (let i = 0; i < 5; i++) {
        gl.uniform4fv(this.u.colors[i], this._palette[i]);
      }
      
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    };
    
    this._animId = requestAnimationFrame(loop);
  }

  stop() {
    if (this._animId) {
      cancelAnimationFrame(this._animId);
      this._animId = null;
    }
    if (this._observer) {
      this._observer.disconnect();
      this._observer = null;
    }
  }
}
