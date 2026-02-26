import 'dart:io';
// import 'package:cpp/firebase/firebase_uploader.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfx/pdfx.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// import 'package:cpp/utils/compressor.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cryptography/cryptography.dart';
import 'package:spdy_message/services/compressor.dart';
import 'package:spdy_message/services/firebase_uploader.dart';

class UploadPage extends StatefulWidget {
  final String? chatId;
  final SecretKey? sharedKey;

  const UploadPage({super.key, this.chatId, this.sharedKey});
  @override
  State<UploadPage> createState() => _UploadPageState();
}

class _UploadPageState extends State<UploadPage> {
  List<PlatformFile> selectedFiles = [];
  List<String> renamedFiles = [];
  double _compressionProgress = 0.0;
  bool _isCompressing = false;
  int _filesUploadedCount = 0;
  bool _isUploading = false;

  // --- YOUR EXISTING LOGIC FUNCTIONS (UNCHANGED) ---

  Future<void> pickFiles({required String type}) async {
    FileType pickerType;
    List<String>? allowedExt;

    if (type == 'pdf') {
      pickerType = FileType.custom;
      allowedExt = ['pdf'];
    } else if (type == 'video') {
      pickerType = FileType.video;
    } else {
      pickerType = FileType.image;
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: pickerType,
      allowedExtensions: allowedExt,
      withData: false,
    );

    if (result == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No file picked')));
      return;
    }

    final newFiles = result.files.where((f) {
      final ext = (f.extension ?? '').toLowerCase();
      if (type == 'pdf') return ext == 'pdf';
      if (type == 'video')
        return ['mp4', 'mov', 'avi', 'mkv', 'flv', 'wmv'].contains(ext);
      return ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp'].contains(ext);
    }).toList();

    if (newFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No allowed files selected')),
      );
      return;
    }

    final existingKeys = selectedFiles.map((e) => e.path ?? e.name).toSet();
    final toAdd = <PlatformFile>[];
    for (final f in newFiles) {
      final key = f.path ?? f.name;
      if (!existingKeys.contains(key)) {
        toAdd.add(f);
        existingKeys.add(key);
      }
    }

    if (toAdd.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No new files to add')));
      return;
    }

    final startIndex = selectedFiles.length;
    setState(() {
      selectedFiles.addAll(toAdd);
      renamedFiles.addAll(
        List<String>.generate(toAdd.length, (i) => toAdd[i].name),
      );
    });

    await _showRenameFlow(startIndex: startIndex, count: toAdd.length);
  }

  Future<void> _showRenameFlow({
    required int startIndex,
    required int count,
  }) async {
    final end = startIndex + count;
    for (int i = startIndex; i < end && i < selectedFiles.length; i++) {
      final newName = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          final ctrl = TextEditingController(text: renamedFiles[i]);
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text('Rename file'),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'New name'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
      if (newName == null) break;
      setState(
        () => renamedFiles[i] = newName.isEmpty ? renamedFiles[i] : newName,
      );
    }
  }

  Future<void> _renameSingle(int index) async {
    final ctrl = TextEditingController(text: renamedFiles[index]);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Rename file'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty)
      setState(() => renamedFiles[index] = newName);
  }

  bool _areAllFilesSmall() {
    const maxSizeInBytes = 50 * 1024 * 1024; // 50 MB
    return selectedFiles.every((file) => file.size <= maxSizeInBytes);
  }

  Future<void> _handleCompressionAttempt() async {
    if (selectedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select files first.')),
      );
      return;
    }

    final bool? shouldProceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text('RENAME BEFORE UPLOAD'),
          content: const Text(
            'Please ensure all documents are named correctly according to content.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('CANCEL'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('PROCEED'),
            ),
          ],
        );
      },
    );

    if (shouldProceed != true) return;

    setState(() {
      _isCompressing = true;
      _compressionProgress = 0.0;
    });

    final compressedPf = await Compressor.compressFiles(
      selectedFiles,
      renamedFiles,
      onProgress: (p) => setState(() => _compressionProgress = p),
    );

    List<PlatformFile> cleanFiles = [];
    for (int i = 0; i < compressedPf.length; i++) {
      final file = compressedPf[i];
      final String desiredName = renamedFiles[i];
      if (file.path != null) {
        final File originalFile = File(file.path!);
        final String dir = p.dirname(file.path!);
        final String newPath = p.join(dir, desiredName);
        try {
          final File newFile = File(newPath);
          if (await newFile.exists()) await newFile.delete();
          await originalFile.rename(newPath);
          cleanFiles.add(
            PlatformFile(
              name: desiredName,
              path: newPath,
              size: await File(newPath).length(),
            ),
          );
        } catch (e) {
          cleanFiles.add(file);
        }
      }
    }

    setState(() {
      _isCompressing = false;
      selectedFiles = cleanFiles;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Compression complete! ${compressedPf.length} file(s) ready',
        ),
      ),
    );
  }

  Future<void> _handleFinalUpload() async {
    if (selectedFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select files before uploading.')),
      );
      return;
    }
    final email = FirebaseAuth.instance.currentUser?.email;
    String phoneNumber = FirebaseAuth.instance.currentUser?.phoneNumber ?? '';
    if (phoneNumber == null || phoneNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User authentication failed.')),
      );
      return;
    }

    setState(() {
      _isUploading = true;
      _filesUploadedCount = 0;
    });

    Map<String, dynamic> result;

    if (widget.chatId != null && widget.sharedKey != null) {
      result = await uploadChatFiles(
        selectedFiles,
        widget.chatId!,
        widget.sharedKey!,
        onFileCompleted: (count) => setState(() => _filesUploadedCount = count),
      );
    } else {
      result = await uploadUserFiles(
        selectedFiles,
        phoneNumber,
        onFileCompleted: (count) => setState(() => _filesUploadedCount = count),
      );
    }

    setState(() => _isUploading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result['message']),
        backgroundColor: result['success'] ? Colors.blue : Colors.red,
      ),
    );

    if (result['success'] && widget.chatId != null) {
      Navigator.pop(context); // Go back to chat screen after successful upload
    }
  }

  // --- UI HELPER WIDGETS ---

  Widget _buildPreview(PlatformFile f) {
    final path = f.path;
    if (path == null) return const Text('No preview available');
    final ext = (f.extension ?? '').toLowerCase();

    if (ext == 'pdf') {
      return SizedBox(
        height: 300,
        child: FutureBuilder<PdfDocument>(
          future: PdfDocument.openFile(path),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done)
              return const Center(child: CircularProgressIndicator());
            if (snapshot.hasError || snapshot.data == null)
              return _openExternalButton(path);
            return PdfView(
              controller: PdfController(document: PdfDocument.openFile(path)),
            );
          },
        ),
      );
    }
    return Image.file(File(path), height: 300, fit: BoxFit.contain);
  }

  Widget _openExternalButton(String srcPath) {
    return Center(
      child: ElevatedButton.icon(
        icon: const Icon(Icons.open_in_new),
        label: const Text('Open PDF (external)'),
        onPressed: () async {
          try {
            final cacheDir = await getTemporaryDirectory();
            final dest = File(p.join(cacheDir.path, p.basename(srcPath)));
            await File(srcPath).copy(dest.path);
            await OpenFile.open(dest.path);
          } catch (e) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Open failed: $e')));
          }
        },
      ),
    );
  }

  Widget _buildFileList() {
    if (selectedFiles.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Text(
            'No files selected yet',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: selectedFiles.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final f = selectedFiles[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            (f.extension?.toLowerCase() == 'pdf')
                ? Icons.picture_as_pdf
                : ([
                        'mp4',
                        'mov',
                        'avi',
                        'mkv',
                        'flv',
                        'wmv',
                      ].contains(f.extension?.toLowerCase())
                      ? Icons.videocam
                      : Icons.image),
            color: const Color(0xFF1A2A3A),
          ),
          title: Text(
            renamedFiles[i],
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            '${(f.size / 1024).toStringAsFixed(1)} KB',
            style: const TextStyle(fontSize: 12),
          ),
          onTap: () => _showPreviewDialog(i, f),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: () => setState(() {
              selectedFiles.removeAt(i);
              renamedFiles.removeAt(i);
            }),
          ),
        );
      },
    );
  }

  void _showPreviewDialog(int i, PlatformFile f) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(renamedFiles[i], style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: _buildPreview(f),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _renameSingle(i);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A2A3A),
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'Upload Documents',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          Container(
            height: 120,
            decoration: const BoxDecoration(
              color: Color(0xFF1A2A3A),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(40),
                bottomRight: Radius.circular(40),
              ),
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
            child: Column(
              children: [
                // STEP 1: PICKER CARD
                _buildCard(
                  title: "Select Files",
                  icon: Icons.add_a_photo_outlined,
                  iconColor: Colors.blue,
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildPickerBtn(
                          icon: Icons.image,
                          label: 'Images',
                          onTap: () => pickFiles(type: 'image'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildPickerBtn(
                          icon: Icons.videocam,
                          label: 'Videos',
                          onTap: () => pickFiles(type: 'video'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildPickerBtn(
                          icon: Icons.picture_as_pdf,
                          label: 'PDFs',
                          onTap: () => pickFiles(type: 'pdf'),
                        ),
                      ),
                    ],
                  ),
                ),

                // STEP 2: FILE LIST CARD
                _buildCard(
                  title: "Queue",
                  icon: Icons.folder_open,
                  iconColor: Colors.orange,
                  child: _buildFileList(),
                ),

                // STEP 3: PROGRESS CARD (Dynamic)
                if (_isCompressing || _isUploading)
                  _buildCard(
                    title: _isCompressing ? "Compressing..." : "Uploading...",
                    icon: Icons.cloud_upload_outlined,
                    iconColor: Colors.green,
                    child: Column(
                      children: [
                        if (_isCompressing) ...[
                          LinearProgressIndicator(
                            value: _compressionProgress,
                            backgroundColor: Colors.grey[200],
                            valueColor: const AlwaysStoppedAnimation(
                              Colors.orange,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${(_compressionProgress * 100).toStringAsFixed(0)}%',
                          ),
                        ],
                        if (_isUploading) ...[
                          Text(
                            'File $_filesUploadedCount of ${selectedFiles.length}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: _filesUploadedCount / selectedFiles.length,
                            minHeight: 8,
                            backgroundColor: Colors.grey[200],
                            valueColor: const AlwaysStoppedAnimation(
                              Color(0xFF1A2A3A),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                const SizedBox(height: 20),

                // ACTIONS
                _buildActionBtn(
                  label: 'COMPRESS',
                  onPressed: selectedFiles.isEmpty
                      ? null
                      : _handleCompressionAttempt,
                  colors: [const Color(0xFF2C3E50), const Color(0xFF4CA1AF)],
                ),
                const SizedBox(height: 12),
                _buildActionBtn(
                  label: 'FINAL UPLOAD',
                  onPressed: (selectedFiles.isEmpty || !_areAllFilesSmall())
                      ? null
                      : _handleFinalUpload,
                  colors: [const Color(0xFF11998e), const Color(0xFF38ef7d)],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // UI HELPERS
  Widget _buildCard({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const Divider(height: 24),
          child,
        ],
      ),
    );
  }

  Widget _buildPickerBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F7FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 20),
            Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionBtn({
    required String label,
    required VoidCallback? onPressed,
    required List<Color> colors,
  }) {
    return Container(
      width: double.infinity,
      height: 55,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        gradient: onPressed == null ? null : LinearGradient(colors: colors),
        color: onPressed == null ? Colors.grey[300] : null,
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
