import 'dart:async';
import 'dart:math';

import 'package:async/async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map/src/core/point.dart';
import 'package:flutter_map/src/gestures/gestures.dart';
import 'package:flutter_map/src/layer/group_layer.dart';
import 'package:flutter_map/src/layer/overlay_image_layer.dart';
import 'package:flutter_map/src/map/map.dart';
import 'package:flutter_map/src/map/map_state_widget.dart';
import 'package:latlong/latlong.dart';
import 'package:positioned_tap_detector/positioned_tap_detector.dart';

class BackgroundLayerOptions extends LayerOptions {
  final List<Background> overlayImages;

  BackgroundLayerOptions({
    Key key,
    this.overlayImages = const [],
    rebuild,
  }) : super(key: key, rebuild: rebuild);
}

class Background {
  final LatLngBounds bounds;
  final ImageProvider imageProvider;
  final double opacity;
  final bool gaplessPlayback;

  Background({
    this.bounds,
    this.imageProvider,
    this.opacity = 1.0,
    this.gaplessPlayback = false,
  });
}

class BackgroundLayerWidget extends StatelessWidget {
  final BackgroundLayerOptions options;

  BackgroundLayerWidget({@required this.options}) : super(key: options.key);

  @override
  Widget build(BuildContext context) {
    final mapState = MapState.of(context);
    return BackgroundLayer(options, mapState, mapState.onMoved);
  }
}

class BackgroundLayer extends StatelessWidget {
  final BackgroundLayerOptions overlayImageOpts;
  final MapState map;
  final Stream<Null> stream;

  BackgroundLayer(this.overlayImageOpts, this.map, this.stream)
      : super(key: overlayImageOpts.key);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: stream,
      builder: (BuildContext context, _) {
        return ClipRect(
          child: Stack(
            children: <Widget>[
              for (var overlayImage in overlayImageOpts.overlayImages)
                _positionedForOverlay(overlayImage),
            ],
          ),
        );
      },
    );
  }

  Positioned _positionedForOverlay(Background overlayImage) {
    final zoomScale =
    map.getZoomScale(map.zoom, map.zoom); // TODO replace with 1?
    final pixelOrigin = map.getPixelOrigin();
    final upperLeftPixel =
        map.project(overlayImage.bounds.northWest).multiplyBy(zoomScale) -
            pixelOrigin;
    final bottomRightPixel =
        map.project(overlayImage.bounds.southEast).multiplyBy(zoomScale) -
            pixelOrigin;
    return Positioned(
      left: upperLeftPixel.x.toDouble(),
      top: upperLeftPixel.y.toDouble(),
      width: (bottomRightPixel.x - upperLeftPixel.x).toDouble(),
      height: (bottomRightPixel.y - upperLeftPixel.y).toDouble(),
      child: Image(
        image: overlayImage.imageProvider,
        fit: BoxFit.fill,
        color: Color.fromRGBO(255, 255, 255, overlayImage.opacity),
        colorBlendMode: BlendMode.modulate,
        gaplessPlayback: overlayImage.gaplessPlayback,
      ),
    );
  }
}

class FlutterMapState extends MapGestureMixin {
  final Key _layerStackKey = GlobalKey();
  final Key _positionedTapDetectorKey = GlobalKey();
  final MapControllerImpl mapController;
  final List<StreamGroup<Null>> groups = <StreamGroup<Null>>[];
  final _positionedTapController = PositionedTapController();
  double rotation = 0.0;

  @override
  MapOptions get options => widget.options ?? MapOptions();

  @override
  MapState mapState;

  FlutterMapState(this.mapController);

  @override
  void didUpdateWidget(FlutterMap oldWidget) {
    mapState.options = options;
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    super.initState();
    mapState = MapState(options);
    rotation = options.rotation;
    mapController.state = mapState;
    mapController.onRotationChanged =
        (degree) => setState(() => rotation = degree);
  }

  void _dispose() {
    for (var group in groups) {
      group.close();
    }

    groups.clear();
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  Stream<Null> _merge(LayerOptions options) {
    if (options?.rebuild == null) return mapState.onMoved;

    var group = StreamGroup<Null>();
    group.add(mapState.onMoved);
    group.add(options.rebuild);
    groups.add(group);
    return group.stream;
  }

  static const _rad90 = 90.0 * pi / 180.0;

  @override
  Widget build(BuildContext context) {
    _dispose();
    return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
      double angle;
      double width;
      double height;

      // only do the rotation maths if we have a rotation
      if (rotation != 0.0) {
        angle = degToRadian(rotation);
        final rangle90 = sin(_rad90 - angle).abs();
        final sinangle = sin(angle).abs();
        // to make sure that the whole screen is filled with the map after rotation
        // we enlarge the drawing area over the available screen size
        width = (constraints.maxWidth * rangle90) +
            (constraints.maxHeight * sinangle);
        height = (constraints.maxHeight * rangle90) +
            (constraints.maxWidth * sinangle);

        mapState.size = CustomPoint<double>(width, height);
      } else {
        mapState.size =
            CustomPoint<double>(constraints.maxWidth, constraints.maxHeight);
      }

      var layerStack = Stack(
        key: _layerStackKey,
        children: [
          ...widget.children ?? [],
          ...widget.layers.map(
                  (layer) => _createLayer(layer, widget.options.plugins)) ??
              [],
        ],
      );

      Widget mapRoot;

      if (!options.interactive) {
        mapRoot = layerStack;
      } else {
        mapRoot = PositionedTapDetector(
          key: _positionedTapDetectorKey,
          controller: _positionedTapController,
          onTap: handleTap,
          onLongPress: handleLongPress,
          onDoubleTap: handleDoubleTap,
          child: GestureDetector(
            onScaleStart: handleScaleStart,
            onScaleUpdate: handleScaleUpdate,
            onScaleEnd: handleScaleEnd,
            onTap: _positionedTapController.onTap,
            onLongPress: _positionedTapController.onLongPress,
            onTapDown: _positionedTapController.onTapDown,
            onTapUp: handleOnTapUp,
            child: layerStack,
          ),
        );
      }

      if (rotation != 0.0) {
        // By using an OverflowBox with the enlarged drawing area all the layers
        // act as if the area really would be that big. So no changes in any layer
        // logic is necessary for the rotation
        return MapStateInheritedWidget(
          mapState: mapState,
          child: ClipRect(
            child: Transform.rotate(
              angle: angle,
              child: OverflowBox(
                minWidth: width,
                maxWidth: width,
                minHeight: height,
                maxHeight: height,
                child: mapRoot,
              ),
            ),
          ),
        );
      } else {
        return MapStateInheritedWidget(
          mapState: mapState,
          child: mapRoot,
        );
      }
    });
  }

  Widget _createLayer(LayerOptions options, List<MapPlugin> plugins) {
    for (var plugin in plugins) {
      if (plugin.supportsLayer(options)) {
        return plugin.createLayer(options, mapState, _merge(options));
      }
    }
    if (options is TileLayerOptions) {
      return TileLayer(
          options: options, mapState: mapState, stream: _merge(options));
    }
    if (options is MarkerLayerOptions) {
      return MarkerLayer(options, mapState, _merge(options));
    }
    if (options is PolylineLayerOptions) {
      return PolylineLayer(options, mapState, _merge(options));
    }
    if (options is PolygonLayerOptions) {
      return PolygonLayer(options, mapState, _merge(options));
    }
    if (options is CircleLayerOptions) {
      return CircleLayer(options, mapState, _merge(options));
    }
    if (options is GroupLayerOptions) {
      return GroupLayer(options, mapState, _merge(options));
    }
    if (options is OverlayImageLayerOptions) {
      return OverlayImageLayer(options, mapState, _merge(options));
    }
    if (options is BackgroundLayerOptions) {
      return BackgroundLayerOptions(options, mapState, _merge(options));
    }
    assert(false, """
Can't find correct layer for $options. Perhaps when you create your FlutterMap you need something like this:

    options: new MapOptions(plugins: [MyFlutterMapPlugin()])""");
    return null;
  }
}
