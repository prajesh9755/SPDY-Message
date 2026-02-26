// lib/utils/compressor.dart
// Full, ready-to-use compressor for on-device image + PDF compression
// Compatible with:
// flutter_image_compress >=2.x (returns XFile from compressAndGetFile)
// pdf_render_plus (rendered.pixels, page.close())
// image >=4.x

import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:video_compress/video_compress.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_render_plus/pdf_render.dart' as pdf_render;
import 'package:image/image.dart' as img_pkg;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:ui' as ui;

class Compressor {
  static const int kMaxBytes = 1048576; // 1 MB (Target size for Image/PDF)
  static const int kMaxUploadBytes =
      50 * 1024 * 1024; // 50 MB (Max total upload)

  /// Compress list of PlatformFile and return new PlatformFile list (in cache)
  /// renamedNames must match length and be final file names (without guaranteeing extension)
  static Future<List<PlatformFile>> compressFiles(
    List<PlatformFile> files,
    List<String> renamedNames, {
    void Function(double progress)? onProgress,
  }) async {
    if (files.length != renamedNames.length) {
      throw ArgumentError('files and renamedNames must have same length');
    }

    final cache = await getTemporaryDirectory();
    final out = <PlatformFile>[];
    final total = files.length;

    for (int i = 0; i < files.length; i++) {
      final pf = files[i];
      final renamed = renamedNames[i];
      try {
        if (pf.path == null) {
          // nothing we can do
          continue;
        }
        final src = File(pf.path!);
        final origSize = await src.length();

        File finalFile;
        if (origSize <= kMaxBytes) {
          finalFile = await _copyToCache(src, renamed, cache);
        } else {
          final ext = p.extension(src.path).toLowerCase();
          if (_isImageExt(ext)) {
            finalFile = await _compressImageFile(src, renamed, cache);
          } else if (_isVideoExt(ext)) {
            finalFile = await _compressVideoFile(src, renamed, cache);
          } else if (ext == '.pdf' || ext == 'pdf') {
            finalFile = await _compressPdfFile(src, renamed, cache);
          } else {
            // unknown: just copy
            finalFile = await _copyToCache(src, renamed, cache);
          }

          // safety: if compressed larger, keep original (copied with renamed name)
          // Except for videos, if we compress we just keep whatever size, as long as under 50MB
          if (await finalFile.length() > origSize) {
            finalFile = await _copyToCache(src, renamed, cache);
          }
        }

        final realName = p.basename(finalFile.path);
        out.add(
          PlatformFile(
            name: realName,
            path: finalFile.path,
            size: await finalFile.length(),
            bytes: null,
          ),
        );
      } catch (e) {
        // fallback copy original
        try {
          if (pf.path != null) {
            final f = await _copyToCache(File(pf.path!), renamed, cache);
            out.add(
              PlatformFile(
                name: p.basename(f.path),
                path: f.path,
                size: await f.length(),
              ),
            );
          }
        } catch (_) {}
      } finally {
        if (onProgress != null) onProgress((i + 1) / total);
      }
    }

    return out;
  }

  // ---------------- helpers ----------------

  static bool _isImageExt(String ext) {
    final e = ext.startsWith('.') ? ext.substring(1) : ext;
    return ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'heic'].contains(e);
  }

  static bool _isVideoExt(String ext) {
    final e = ext.startsWith('.') ? ext.substring(1) : ext;
    return ['mp4', 'mov', 'avi', 'mkv', 'flv', 'wmv'].contains(e);
  }

  static Future<File> _copyToCache(
    File src,
    String renamed,
    Directory cache,
  ) async {
    final safeName = renamed;
    final out = File(
      p.join(cache.path, '${DateTime.now().microsecondsSinceEpoch}_$safeName'),
    );
    return await src.copy(out.path);
  }

  // ---------------- image compression ----------------

  static Future<File> _compressImageFile(
    File src,
    String renamed,
    Directory cache,
  ) async {
    final outBase =
        '${DateTime.now().microsecondsSinceEpoch}_${p.basenameWithoutExtension(renamed)}.jpg';
    final outPath = p.join(cache.path, outBase);

    // Single pass aggressive compression like WhatsApp (resizes to max 1280x1280 and 70% quality)
    final xfile = await FlutterImageCompress.compressAndGetFile(
      src.path,
      outPath,
      minWidth: 1280,
      minHeight: 1280,
      quality: 70,
    );

    if (xfile != null) {
      return File(xfile.path);
    }

    // fallback
    return await _copyToCache(src, renamed, cache);
  }

  // ---------------- video compression ----------------

  static Future<File> _compressVideoFile(
    File src,
    String renamed,
    Directory cache,
  ) async {
    final info = await VideoCompress.compressVideo(
      src.path,
      quality: VideoQuality
          .LowQuality, // LowQuality is instantly fast and matches WhatsApp limits
      deleteOrigin: false,
      includeAudio: true,
    );
    if (info != null && info.file != null) {
      final safeName = renamed.toLowerCase().endsWith('.mp4')
          ? renamed
          : '$renamed.mp4';
      final outPath = p.join(
        cache.path,
        '${DateTime.now().microsecondsSinceEpoch}_$safeName',
      );
      return await info.file!.copy(outPath);
    }
    return await _copyToCache(src, renamed, cache);
  }

  // ---------------- PDF compression (rasterize + rebuild) ----------------

  static Future<File> _compressPdfFile(
    File src,
    String renamed,
    Directory cache,
  ) async {
    final safeName = renamed.toLowerCase().endsWith('.pdf')
        ? renamed
        : '$renamed.pdf';
    final out1 = p.join(
      cache.path,
      '${DateTime.now().microsecondsSinceEpoch}_$safeName',
    );
    final out2 = p.join(
      cache.path,
      '${DateTime.now().microsecondsSinceEpoch}_2_$safeName',
    );

    final pdf1 = await _buildPdfFromScale(src, 1.0, 80, out1);
    if (await pdf1.length() <= kMaxBytes) return pdf1;

    final pdf2 = await _buildPdfFromScale(src, 0.7, 70, out2);
    return (await pdf2.length() <= await pdf1.length()) ? pdf2 : pdf1;
  }

  // rasterize pages using pdf_render_plus API (rendered.pixels), convert to JPG and rebuild PDF
  static Future<File> _buildPdfFromScale(
    File src,
    double scale,
    int jpgQuality,
    String outPath,
  ) async {
    final doc = await pdf_render.PdfDocument.openFile(src.path);
    final pdf = pw.Document();

    try {
      for (int pageNum = 1; pageNum <= doc.pageCount; pageNum++) {
        final page = await doc.getPage(pageNum);

        final width = (page.width * scale).round().clamp(200, 3000);
        final height = (page.height * scale).round().clamp(200, 3000);

        // ---------- call render with several fallbacks ----------
        dynamic rendered;
        try {
          // preferred: named parameters
          rendered = await (page as dynamic).render(
            width: width,
            height: height,
          );
        } catch (_) {
          try {
            // try positional
            rendered = await (page as dynamic).render(width, height);
          } catch (_) {
            try {
              // try with bytes flag named
              rendered = await (page as dynamic).render(
                width: width,
                height: height,
                bytes: true,
              );
            } catch (_) {
              // last resort: any call
              rendered = await (page as dynamic).render();
            }
          }
        }

        // ---------- extract image bytes ----------
        Uint8List? imageBytes;
        int renderedWidth = width;
        int renderedHeight = height;

        // case A: rendered has 'bytes' which is encoded PNG/JPEG
        try {
          final dyn = rendered as dynamic;
          if (dyn.bytes != null) {
            imageBytes = dyn.bytes as Uint8List?;
          }
        } catch (_) {}

        // case B: rendered has 'pixels' (raw RGBA)
        Uint8List? rgba;
        try {
          final dyn = rendered as dynamic;
          if (dyn.pixels != null) {
            rgba = dyn.pixels as Uint8List?;
            // try to get width/height if available on object
            try {
              renderedWidth = dyn.width as int;
            } catch (_) {}
            try {
              renderedHeight = dyn.height as int;
            } catch (_) {}
          }
        } catch (_) {}

        // case C: rendered has 'image' (ui.Image) -> convert to PNG bytes
        if (imageBytes == null && rgba == null) {
          try {
            final dyn = rendered as dynamic;
            final uiImg = dyn.image as dynamic;
            if (uiImg != null) {
              final bd = await uiImg.toByteData(format: ui.ImageByteFormat.png);
              imageBytes = bd?.buffer.asUint8List();
              // override dims if present
              try {
                renderedWidth = uiImg.width as int;
              } catch (_) {}
              try {
                renderedHeight = uiImg.height as int;
              } catch (_) {}
            }
          } catch (_) {}
        }

        // close page (try both close() and dispose() safely)
        try {
          await (page as dynamic).close();
        } catch (_) {
          try {
            await (page as dynamic).dispose();
          } catch (_) {}
        }

        // ---------- convert to jpg bytes ----------
        Uint8List? jpgBytes;

        if (imageBytes != null) {
          // imageBytes are encoded PNG/JPEG — decode via image package then re-encode to JPG
          final decoded = img_pkg.decodeImage(imageBytes);
          if (decoded != null) {
            jpgBytes = img_pkg.encodeJpg(decoded, quality: jpgQuality);
          }
        } else if (rgba != null) {
          // raw RGBA -> create img_pkg.Image by per-pixel copy
          try {
            // create Image with named params
            final img = img_pkg.Image(
              width: renderedWidth,
              height: renderedHeight,
            );

            int idx = 0;
            for (int y = 0; y < renderedHeight; y++) {
              for (int x = 0; x < renderedWidth; x++) {
                if (idx + 3 >= rgba.length) break;
                final int r = rgba[idx];
                final int g = rgba[idx + 1];
                final int b = rgba[idx + 2];
                final int a = rgba[idx + 3];
                idx += 4;
                img.setPixelRgba(x, y, r & 0xFF, g & 0xFF, b & 0xFF, a & 0xFF);
              }
            }

            jpgBytes = img_pkg.encodeJpg(img, quality: jpgQuality);
          } catch (_) {
            jpgBytes = null;
          }
        }

        if (jpgBytes == null) {
          // skip page if we couldn't get image bytes
          continue;
        }

        final mem = pw.MemoryImage(jpgBytes);
        pdf.addPage(
          pw.Page(
            build: (_) =>
                pw.Center(child: pw.Image(mem, fit: pw.BoxFit.contain)),
          ),
        );
      }
    } finally {
      // close doc safely (try both close & dispose)
      try {
        await (doc as dynamic).close();
      } catch (_) {
        try {
          await (doc as dynamic).dispose();
        } catch (_) {}
      }
    }

    final outFile = File(outPath);
    await outFile.writeAsBytes(await pdf.save());
    return outFile;
  }
}
