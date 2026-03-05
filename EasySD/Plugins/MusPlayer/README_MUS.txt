EasySD MUS plugin (Compute! Enhanced SID Player)

This plugin expects an external player binary on the SD card:

  SIDPLAYER.PRG  (must be assembled for base address $9000)

Then, selecting any .MUS file in the EasySD menu will load:
  - SIDPLAYER.PRG to $9000
  - the selected .MUS to $8000 (auto-detects RAW vs PRG-wrapped MUS)
  - starts playback, SPACE/STOP to exit back to menu

SD card files required:
  - MUSPLUGIN.PRG  (built from Plugins/MusPlayer)
  - SIDPLAYER.PRG  (you build from the KickAssembler source by setting PLAYER_ADDRESS=$9000)
  - your songs: *.MUS

Build integration:
  - Build - EasySD.bat has been patched to build MusPlayer plugin.
