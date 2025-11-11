part of three_webgl;

class RenderItem {
  int id = 0;
  Object3D? object;
  BufferGeometry? geometry;
  Material? material;
  dynamic program;
  int groupOrder = 0;
  int renderOrder = 0;
  double z = 0;
  Map<String, dynamic>? group;

  void setFrom(
    Object3D object,
    BufferGeometry? geometry,
    Material? material,
    int groupOrder,
    double z,
    Map<String, dynamic>? group,
  ) {
    id = object.id;
    this.object = object;
    this.geometry = geometry;
    this.material = material;
    this.program = null; // set later by renderer
    this.groupOrder = groupOrder;
    this.renderOrder = object.renderOrder;
    this.z = z;
    this.group = group;
  }

  /// List housekeeping only. **Do not** dispose GPU resources here.
  void clearRefs() {
    id = 0;
    object = null;
    geometry = null;
    material = null;
    program = null;
    group = null;
    // leave numbers alone; they get overwritten on reuse
  }
}

class WebGLRenderList {
  WebGLRenderList();

  // Pool of items; indices 0..renderItemsIndex-1 are used this frame.
  final List<RenderItem?> renderItems = <RenderItem?>[];
  int renderItemsIndex = 0;

  final List<RenderItem> opaque = [];
  final List<RenderItem> transmissive = [];
  final List<RenderItem> transparent = [];

  void init() {
    renderItemsIndex = 0;
    opaque.clear();
    transmissive.clear();
    transparent.clear();
  }

  RenderItem _acquire() {
    if (renderItemsIndex >= renderItems.length) {
      final item = RenderItem();
      renderItems.add(item);
      return item;
    }
    final item = renderItems[renderItemsIndex]!;
    return item;
  }

  RenderItem getNextRenderItem(
    Object3D object,
    BufferGeometry? geometry,
    Material? material,
    int groupOrder,
    double z,
    Map<String, dynamic>? group,
  ) {
    final item = _acquire();
    item.setFrom(object, geometry, material!, groupOrder, z, group);
    renderItemsIndex++;
    return item;
  }

  void push(
    Object3D object,
    BufferGeometry geometry,
    Material material,
    int groupOrder,
    double z,
    Map<String, dynamic>? group,
  ) {
    final ri = getNextRenderItem(
      object,
      geometry,
      material,
      groupOrder,
      z,
      group,
    );
    if (material.transmission > 0.0) {
      transmissive.add(ri);
    } else if (material.transparent) {
      transparent.add(ri);
    } else {
      opaque.add(ri);
    }
  }

  /// Teardown for renderer-wide disposal.
  /// CPU-side only: do NOT dispose geometry/material/object here.
  void dispose() {
    for (int i = 0; i < renderItems.length; i++) {
      renderItems[i]?.clearRefs();
      renderItems[i] = null;
    }
    renderItems.clear();
    opaque.clear();
    transmissive.clear();
    transparent.clear();
    renderItemsIndex = 0;
  }

  void unshift(
    Object3D object,
    BufferGeometry? geometry,
    Material? material,
    int groupOrder,
    double z,
    Map<String, dynamic>? group,
  ) {
    final ri = getNextRenderItem(
      object,
      geometry,
      material!,
      groupOrder,
      z,
      group,
    );
    if (material.transmission > 0.0) {
      transmissive.insert(0, ri);
    } else if (material.transparent) {
      transparent.insert(0, ri);
    } else {
      opaque.insert(0, ri);
    }
  }

  void sort(customOpaqueSort, customTransparentSort) {
    if (opaque.length > 1) {
      opaque.sort(customOpaqueSort ?? painterSortStable);
    }
    if (transmissive.length > 1) {
      transmissive.sort(customTransparentSort ?? reversePainterSortStable);
    }
    if (transparent.length > 1) {
      transparent.sort(customTransparentSort ?? reversePainterSortStable);
    }
  }

  void finish() {
    // clear unused items’ refs so GC can reclaim
    for (int i = renderItemsIndex; i < renderItems.length; i++) {
      final ri = renderItems[i];
      if (ri == null) break;
      ri.clearRefs();
    }

    // optional: shrink if massively over-allocated
    if (renderItems.length > renderItemsIndex * 2) {
      renderItems.length = renderItemsIndex;
    }
  }

  int painterSortStable(RenderItem a, RenderItem b) {
    if (a.groupOrder != b.groupOrder) {
      return a.groupOrder - b.groupOrder;
    } else if (a.renderOrder != b.renderOrder) {
      return (a.renderOrder - b.renderOrder) > 0 ? 1 : -1;
    } else if (a.program != b.program) {
      return a.program.id - b.program.id;
    } else if (a.material!.id != b.material!.id) {
      return a.material!.id - b.material!.id;
    } else if (a.z != b.z) {
      return (a.z - b.z) > 0 ? 1 : -1;
    } else {
      return a.id - b.id;
    }
  }

  int reversePainterSortStable(RenderItem a, RenderItem b) {
    if (a.groupOrder != b.groupOrder) {
      return a.groupOrder - b.groupOrder;
    } else if (a.renderOrder != b.renderOrder) {
      return a.renderOrder - b.renderOrder;
    } else if (a.z != b.z) {
      final v = b.z - a.z;
      return v > 0 ? 1 : -1;
    } else {
      return a.id - b.id;
    }
  }
}
