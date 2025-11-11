part of three_webgl;

class WebGLUniformsGroups {
  WebGLState state;
  WebGLCapabilities capabilities;
  WebGLInfo info;

  Map buffers = {};
  Map updateList = {};
  List<int> allocatedBindingPoints = [];
  RenderingContext gl;

  late final int
  maxBindingPoints; // binding points are global whereas block indices are per shader program

  WebGLUniformsGroups(this.gl, this.info, this.capabilities, this.state) {
    maxBindingPoints = gl.getParameter(WebGL.MAX_UNIFORM_BUFFER_BINDINGS);
  }

  void bind(UniformsGroup uniformsGroup, WebGLProgram? program) {
    final webglProgram = program?.program;
    state.uniformBlockBinding(uniformsGroup, webglProgram);
  }

  void update(uniformsGroup, WebGLProgram? program) {
    dynamic buffer = buffers[uniformsGroup.id];

    if (buffer == null) {
      prepareUniformsGroup(uniformsGroup);
      buffer = createBuffer(uniformsGroup);
      buffers[uniformsGroup.id] = buffer;
      uniformsGroup.addEventListener('dispose', onUniformsGroupsDispose);
    }

    // ensure to update the binding points/block indices mapping for this program

    final webglProgram = program?.program;
    state.updateUBOMapping(uniformsGroup, webglProgram!);

    // update UBO once per frame

    final frame = info.render['frame'];

    if (updateList[uniformsGroup.id] != frame) {
      updateBufferData(uniformsGroup);
      updateList[uniformsGroup.id] = frame;
    }
  }

  Buffer createBuffer(UniformsGroup uniformsGroup) {
    final bindingPointIndex = allocateBindingPointIndex();
    uniformsGroup.bindingPointIndex = bindingPointIndex;

    final buffer = gl.createBuffer();
    final size = uniformsGroup.size;
    final usage = uniformsGroup.usage;

    gl.bindBuffer(WebGL.UNIFORM_BUFFER, buffer);
    gl.bufferData(WebGL.UNIFORM_BUFFER, size!, usage);
    gl.bindBuffer(WebGL.UNIFORM_BUFFER, null);
    gl.bindBufferBase(WebGL.UNIFORM_BUFFER, bindingPointIndex, buffer);

    return buffer;
  }

  int allocateBindingPointIndex() {
    for (int i = 0; i < maxBindingPoints; i++) {
      if (!allocatedBindingPoints.contains(i)) {
        allocatedBindingPoints.add(i);
        return i;
      }
    }

    console.error(
      'THREE.WebGLRenderer: Maximum number of simultaneously usable uniforms groups reached.',
    );
    return 0;
  }

  void updateBufferData(UniformsGroup uniformsGroup) {
    final buffer = buffers[uniformsGroup.id];
    if (buffer == null) return;

    final uniforms = uniformsGroup.uniforms;
    final Map cache = uniformsGroup.cache ??=
        <String, dynamic>{}; // ensure non-null

    gl.bindBuffer(WebGL.UNIFORM_BUFFER, buffer);

    for (int i = 0, il = uniforms.length; i < il; i++) {
      final uniformEntry = uniforms[i];
      final List uniformArray = (uniformEntry is List)
          ? (uniformEntry as List) // 👈 cast here
          : <dynamic>[uniformEntry];

      for (int j = 0, jl = uniformArray.length; j < jl; j++) {
        final uniform = uniformArray[j];

        if (hasUniformChanged(uniform, i, j, cache)) {
          final int offset = uniform.offset as int;
          final List values = (uniform.value is List)
              ? uniform.value as List
              : [uniform.value];

          final data = uniform.data as Float32Array;
          int arrayOffset = 0;

          for (int k = 0; k < values.length; k++) {
            final value = values[k];
            final info = getUniformSize(value);

            if (value is num || value is bool) {
              data[0] = (value is bool)
                  ? (value ? 1.0 : 0.0)
                  : value.toDouble();
            } else if (value is Matrix3) {
              // std140 mat3 as 3 vec4 = 12 floats
              data[0] = value.storage[0];
              data[1] = value.storage[1];
              data[2] = value.storage[2];
              data[3] = 0.0;
              data[4] = value.storage[3];
              data[5] = value.storage[4];
              data[6] = value.storage[5];
              data[7] = 0.0;
              data[8] = value.storage[6];
              data[9] = value.storage[7];
              data[10] = value.storage[8];
              data[11] = 0.0;
            } else {
              // Vector2/3/4, Matrix4, Color etc
              value.toArray(data, arrayOffset);
              arrayOffset += info['storage']! ~/ Float32List.bytesPerElement;
            }
          }

          gl.bufferSubData(WebGL.UNIFORM_BUFFER, offset, data);
        }
      }
    }

    gl.bindBuffer(WebGL.UNIFORM_BUFFER, null);
  }

  bool hasUniformChanged(
    dynamic uniform,
    int index,
    int indexArray,
    Map cache,
  ) {
    final value = uniform.value;
    final key = '${index}_$indexArray';

    if (!cache.containsKey(key)) {
      cache[key] = (value is num || value is bool) ? value : value.clone();
      return true;
    }

    final cached = cache[key];

    if (value is num || value is bool) {
      if (cached != value) {
        cache[key] = value;
        return true;
      }
    } else {
      if (!cached.equals(value)) {
        cached.copy(value);
        return true;
      }
    }

    return false;
  }

  WebGLUniformsGroups prepareUniformsGroup(UniformsGroup uniformsGroup) {
    final uniforms = uniformsGroup.uniforms;

    int offset = 0; // bytes
    const int chunkSize = 16; // std140 base alignment in bytes

    for (int i = 0, l = uniforms.length; i < l; i++) {
      final uniformEntry = uniforms[i];
      final List uniformArray = (uniformEntry is List)
          ? (uniformEntry as List) // 👈 cast here
          : <dynamic>[uniformEntry];

      for (int j = 0, jl = uniformArray.length; j < jl; j++) {
        final uniform = uniformArray[j]; // dynamic, should have .value

        final values = (uniform.value is List)
            ? uniform.value as List
            : [uniform.value];

        for (int k = 0, kl = values.length; k < kl; k++) {
          final value = values[k];
          final info = getUniformSize(value);

          final chunkOffset = offset % chunkSize;
          final chunkPadding = chunkOffset % info['boundary']!;
          final chunkStart = chunkOffset + chunkPadding;

          offset += chunkPadding;

          if (chunkStart != 0 && (chunkSize - chunkStart) < info['storage']!) {
            offset += (chunkSize - chunkStart);
          }

          // Allocate storage for this uniform in the UBO
          uniform.data = Float32Array(
            info['storage']! ~/ Float32List.bytesPerElement,
          );
          uniform.offset = offset;

          offset += info['storage']!;
        }
      }
    }

    // final padding to 16-byte multiple
    final chunkOffset = offset % chunkSize;
    if (chunkOffset > 0) offset += (chunkSize - chunkOffset);

    uniformsGroup.size = offset;
    uniformsGroup.cache = <String, dynamic>{};

    return this;
  }

  Map<String, int> getUniformSize(value) {
    final Map<String, int> info = {
      'boundary': 0, // bytes
      'storage': 0, // bytes
    };

    // determine sizes according to STD140

    if (value is double || value is int || value is num || value is bool) {
      info['boundary'] = 4;
      info['storage'] = 4;
    } else if (value is Vector2) {
      info['boundary'] = 8;
      info['storage'] = 8;
    } else if (value is Vector3 || value is Color) {
      info['boundary'] = 16;
      info['storage'] =
          12; // evil: vec3 must start on a 16-byte boundary but it only consumes 12 bytes
    } else if (value is Vector4) {
      info['boundary'] = 16;
      info['storage'] = 16;
    } else if (value is Matrix3) {
      info['boundary'] = 48;
      info['storage'] = 48;
    } else if (value is Matrix4) {
      info['boundary'] = 64;
      info['storage'] = 64;
    } else if (value is Texture) {
      console.warning(
        'THREE.WebGLRenderer: Texture samplers can not be part of an uniforms group.',
      );
    } else {
      console.warning(
        'THREE.WebGLRenderer: Unsupported uniform value type. $value',
      );
    }

    return info;
  }

  void onUniformsGroupsDispose(event) {
    final uniformsGroup = event.target;

    uniformsGroup.removeEventListener('dispose', onUniformsGroupsDispose);

    final idx = allocatedBindingPoints.indexOf(
      uniformsGroup.bindingPointIndex as int,
    );
    if (idx != -1) {
      allocatedBindingPoints.removeAt(idx);
    }

    final buffer = buffers[uniformsGroup.id];
    if (buffer != null) {
      gl.deleteBuffer(buffer);
    }

    buffers.remove(uniformsGroup.id);
    updateList.remove(uniformsGroup.id);
  }

  void dispose() {
    for (final id in buffers.keys) {
      gl.deleteBuffer(buffers[id]);
    }

    allocatedBindingPoints = [];
    buffers = {};
    updateList = {};
  }

  void debugPrintStats() {
    debugPrint(
      '[WebGLUniformsGroups][leak-check] '
      'buffers=${buffers.length} '
      'updateList=${updateList.length} '
      'allocatedBindingPoints=${allocatedBindingPoints.length}/$maxBindingPoints',
    );
  }
}
