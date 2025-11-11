part of three_webgl;

class WebGLRenderState {
  bool _didDispose = false;
  late WebGLLights lights;
  WebGLExtensions extensions;
  List<Light> lightsArray = [];
  List<Light> shadowsArray = [];
  Map transmissionRenderTarget = {};
  late RenderState _renderState;

  WebGLRenderState(this.extensions) {
    lights = WebGLLights(extensions);
    _renderState = RenderState(lights, lightsArray, shadowsArray, null, {});
  }

  RenderState get state => _renderState;

  void disposeTransmissionTargets() {
    if (state.transmissionRenderTarget.isEmpty) return;
    state.transmissionRenderTarget.forEach((_, rt) {
      try {
        (rt as RenderTarget).dispose();
      } catch (_) {}
    });
    state.transmissionRenderTarget.clear();
  }

  void pruneTransmissionTargets(Set<int> liveCameraIds) {
    if (state.transmissionRenderTarget.isEmpty) return;
    final dead = <int>[];
    state.transmissionRenderTarget.forEach((key, value) {
      if (!liveCameraIds.contains(key)) {
        try {
          (value as RenderTarget).dispose();
        } catch (_) {}
        dead.add(key);
      }
    });
    for (final k in dead) state.transmissionRenderTarget.remove(k);
  }

  void dispose() {
    if (_didDispose) return;
    _didDispose = true;

    // make sure RTs go first
    disposeTransmissionTargets();

    lightsArray.clear();
    shadowsArray.clear();
    lights.dispose();
    // IMPORTANT: do NOT dispose renderer-owned extensions here.
    // extensions.dispose();  // ← remove this
  }

  void init(Camera camera) {
    state.camera = camera;
    lightsArray.length = 0;
    shadowsArray.length = 0;
  }

  void pushLight(Light light) => lightsArray.add(light);
  void pushShadow(Light shadowLight) => shadowsArray.add(shadowLight);
  void setupLights([bool? physicallyCorrectLights]) =>
      lights.setup(lightsArray, physicallyCorrectLights);
  void setupLightsView(Camera camera) => lights.setupView(lightsArray, camera);
}

class WebGLRenderStates {
  WebGLExtensions extensions;
  WeakMap renderStates = WeakMap();

  // NEW: keep our own strong refs to every WebGLRenderState we create
  final List<WebGLRenderState> _allStates = [];

  WebGLRenderStates(this.extensions);

  WebGLRenderState get(Object3D scene, {int renderCallDepth = 0}) {
    WebGLRenderState renderState;

    if (!renderStates.has(scene)) {
      renderState = WebGLRenderState(extensions);
      renderStates.add(key: scene, value: [renderState]);
      _allStates.add(renderState);
    } else {
      final arr = renderStates.get(scene);
      if (renderCallDepth >= arr.length) {
        renderState = WebGLRenderState(extensions);
        arr.add(renderState);
        _allStates.add(renderState);
      } else {
        renderState = arr[renderCallDepth];
      }
    }

    return renderState;
  }

  void pruneTransmissionTargets(Set<int> liveCameraIds) {
    for (final rs in _allStates) {
      rs.pruneTransmissionTargets(liveCameraIds);
    }
  }

  void dispose() {
    // NEW: free per-state resources before clearing the WeakMap
    for (final rs in _allStates) {
      rs.disposeTransmissionTargets();
      rs.dispose(); // safe: this won’t touch renderer-owned extensions
    }
    _allStates.clear();
    renderStates.clear();
  }
}

class RenderState {
  WebGLLights lights;
  List<Light> lightsArray;
  List<Light> shadowsArray;
  Camera? camera;
  Map transmissionRenderTarget; // (int cameraId -> RenderTarget)

  RenderState(
    this.lights,
    this.lightsArray,
    this.shadowsArray,
    this.camera,
    this.transmissionRenderTarget,
  );
}
