# Owon_XDS2102A Bin file Reader

Tool to display bin files created by an Owon XDS2102A Oscilloscope.

File format:

SPBXDS followed by the 4 Bytes length of the following JSON description  
eg.: A8020000 meaning 680 Bytes of JSON description
![Owon Image](https://github.com/frcocoatst/Owon_XDS2102A_v8/Owon_XDS2102A_v8/blob/master/p0.jpg)


followed by 10000 2Bytes Values (corresponds Data_length 10000 in JSON block)
![Owon Image](https://github.com/frcocoatst/Owon_XDS2102A/blob/master/p2.jpg)

In case a second channel is stored the JSON block is longer
eg.: 09050000 meaning 1289 Bytes of JSON description
![Owon Image](https://github.com/frcocoatst/Owon_XDS2102A/blob/master/p1.jpg)

Followed by 2 * 10000 2 Bytes Values ...

Hint: This is very experimental, not sure if I decode the values right ...



## Swift 5 / Xcode 15.2 parser update (2026)

The OWON BIN reader was made bounds-safe for Swift 5. The parser now validates the SPBXDS signature, reads little-endian JSON and channel block lengths sequentially, tolerates OWON trailing commas in the JSON header, supports the newer 4-byte channel-length field, and falls back to the legacy raw-channel layout. ChannelView also checks byte counts before decoding Int16 samples.
