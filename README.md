# Owon_XDS2102A Bin file Reader

Tool to display bin files created by an Owon XDS2102A Oscilloscope.

## Documentation
📄 [Owon XDS2102A Documentation (PDF)](Owon_XDS2102A_v8_Doku.pdf)
 
## Swift 5 / Xcode 15.2 parser update (2026)

The OWON BIN reader was made bounds-safe for Swift 5. The parser now validates the SPBXDS signature, reads little-endian JSON and channel block lengths sequentially, tolerates OWON trailing commas in the JSON header, supports the newer 4-byte channel-length field, and falls back to the legacy raw-channel layout. ChannelView also checks byte counts before decoding Int16 samples.
