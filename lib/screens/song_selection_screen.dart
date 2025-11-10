import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import 'voice_recording_screen.dart';

class SongSelectionScreen extends StatefulWidget {
  const SongSelectionScreen({super.key});

  @override
  State<SongSelectionScreen> createState() => _SongSelectionScreenState();
}

class _SongSelectionScreenState extends State<SongSelectionScreen> {
  String? _selectedSongId;
  
  final List<Map<String, dynamic>> _songs = [
    {
      'id': '1',
      'title': 'Shape of You',
      'artist': 'Ed Sheeran',
      'duration': '3:53',
      'genre': 'Pop',
      'difficulty': 'Easy',
      'previewUrl': 'https://example.com/preview1.mp3',
      'imageUrl': 'https://via.placeholder.com/150x150/667eea/ffffff?text=ES',
    },
    {
      'id': '2',
      'title': 'Blinding Lights',
      'artist': 'The Weeknd',
      'duration': '3:20',
      'genre': 'Synth-pop',
      'difficulty': 'Medium',
      'previewUrl': 'https://example.com/preview2.mp3',
      'imageUrl': 'https://via.placeholder.com/150x150/764ba2/ffffff?text=TW',
    },
    {
      'id': '3',
      'title': 'Levitating',
      'artist': 'Dua Lipa',
      'duration': '3:23',
      'genre': 'Disco-pop',
      'difficulty': 'Easy',
      'previewUrl': 'https://example.com/preview3.mp3',
      'imageUrl': 'https://via.placeholder.com/150x150/f093fb/ffffff?text=DL',
    },
    {
      'id': '4',
      'title': 'Watermelon Sugar',
      'artist': 'Harry Styles',
      'duration': '2:54',
      'genre': 'Pop Rock',
      'difficulty': 'Medium',
      'previewUrl': 'https://example.com/preview4.mp3',
      'imageUrl': 'https://via.placeholder.com/150x150/f5576c/ffffff?text=HS',
    },
    {
      'id': '5',
      'title': 'Good 4 U',
      'artist': 'Olivia Rodrigo',
      'duration': '2:58',
      'genre': 'Pop Punk',
      'difficulty': 'Hard',
      'previewUrl': 'https://example.com/preview5.mp3',
      'imageUrl': 'https://via.placeholder.com/150x150/4facfe/ffffff?text=OR',
    },
    {
      'id': '6',
      'title': 'Stay',
      'artist': 'The Kid LAROI & Justin Bieber',
      'duration': '2:21',
      'genre': 'Pop',
      'difficulty': 'Easy',
      'previewUrl': 'https://example.com/preview6.mp3',
      'imageUrl': 'https://via.placeholder.com/150x150/00d4aa/ffffff?text=KL',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppColors.primaryGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back, color: AppColors.white),
                    ),
                    Expanded(
                      child: Text(
                        'Choose Your Song',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: AppColors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 48), // Balance the back button
                  ],
                ),
              ),
              
              // Search Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.white.withOpacity(0.3)),
                  ),
                  child: TextField(
                    style: const TextStyle(color: AppColors.white),
                    decoration: InputDecoration(
                      hintText: 'Search songs...',
                      hintStyle: TextStyle(color: AppColors.white.withOpacity(0.7)),
                      prefixIcon: Icon(Icons.search, color: AppColors.white.withOpacity(0.7)),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Songs List
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(24),
                      topRight: Radius.circular(24),
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 24),
                      Text(
                        'Popular Songs',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _songs.length,
                          itemBuilder: (context, index) {
                            final song = _songs[index];
                            final isSelected = _selectedSongId == song['id'];
                            
                            return Container(
                              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected ? AppColors.primarySaffron.withOpacity(0.1) : null,
                                borderRadius: BorderRadius.circular(12),
                                border: isSelected 
                                    ? Border.all(color: AppColors.primarySaffron, width: 2)
                                    : null,
                              ),
                              child: ListTile(
                                leading: Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    gradient: const LinearGradient(
                                      colors: [AppColors.primarySaffron, AppColors.lightSaffron],
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      song['artist'].toString().split(' ').map((e) => e[0]).join(''),
                                      style: const TextStyle(
                                        color: AppColors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                ),
                                title: Text(
                                  song['title'],
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isSelected ? AppColors.primarySaffron : AppColors.textPrimary,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      song['artist'],
                                      style: const TextStyle(color: AppColors.textSecondary),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        _buildChip(song['genre'], AppColors.successGreen),
                                        const SizedBox(width: 8),
                                        _buildChip(song['difficulty'], _getDifficultyColor(song['difficulty'])),
                                        const SizedBox(width: 8),
                                        Icon(
                                          Icons.access_time,
                                          size: 16,
                                          color: AppColors.textSecondary,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          song['duration'],
                                          style: const TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                trailing: IconButton(
                                  onPressed: () {
                                    // Play preview
                                    _playPreview(song['previewUrl']);
                                  },
                                  icon: const Icon(Icons.play_circle_outline),
                                  color: AppColors.primarySaffron,
                                ),
                                onTap: () {
                                  setState(() {
                                    _selectedSongId = song['id'];
                                  });
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              
              // Continue Button
              if (_selectedSongId != null)
                Container(
                  padding: const EdgeInsets.all(24),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        final selectedSong = _songs.firstWhere((s) => s['id'] == _selectedSongId);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => VoiceRecordingScreen(
                              songTitle: selectedSong['title'],
                              songArtist: selectedSong['artist'],
                            ),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primarySaffron,
                        foregroundColor: AppColors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Continue to Recording',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
  
  Color _getDifficultyColor(String difficulty) {
    switch (difficulty.toLowerCase()) {
      case 'easy':
        return AppColors.successGreen;
      case 'medium':
        return AppColors.warningOrange;
      case 'hard':
        return AppColors.errorRed;
      default:
        return AppColors.textSecondary;
    }
  }
  
  void _playPreview(String previewUrl) {
    // TODO: Implement audio preview
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Playing preview...'),
        backgroundColor: AppColors.primarySaffron,
      ),
    );
  }
}
