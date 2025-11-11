part of three_webgl;

class WebGLRenderLists {
  WebGLRenderLists();
  WeakMap lists = WeakMap();

  WebGLRenderList get(scene, int renderCallDepth) {
    final listArray = lists.get(scene);
    WebGLRenderList list;

    if (!lists.has(scene)) {
      list = WebGLRenderList();
      lists.add(key: scene, value: [list]);
    } else {
      if (renderCallDepth >= listArray.length) {
        list = WebGLRenderList();
        listArray.add(list);
      } else {
        list = listArray[renderCallDepth];
      }
    }
    return list;
  }

  void dispose() {
    lists.clear();
  }
}
