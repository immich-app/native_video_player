// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'video_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

VideoInfo _$VideoInfoFromJson(Map<String, dynamic> json) => VideoInfo(
      height: (json['height'] as num).toInt(),
      width: (json['width'] as num).toInt(),
      duration: (json['duration'] as num).toInt(),
    );

Map<String, dynamic> _$VideoInfoToJson(VideoInfo instance) => <String, dynamic>{
      'height': instance.height,
      'width': instance.width,
      'duration': instance.duration,
    };
