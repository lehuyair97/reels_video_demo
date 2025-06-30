const express = require("express");
const cors = require("cors");
const multer = require("multer");
const ffmpeg = require("fluent-ffmpeg");
const fs = require("fs");
const path = require("path");
const { v4: uuidv4 } = require("uuid");
const mongoose = require("mongoose");
const { exec } = require("child_process");
const Queue = require("bull");

const app = express();
const PORT = 4000;

// MongoDB Atlas connection
mongoose
  .connect(
    "mongodb+srv://lehuyair97:Lehuy1997@lehuy.d7b1k90.mongodb.net/testVideo?retryWrites=true&w=majority&appName=LeHuy",
    { useNewUrlParser: true, useUnifiedTopology: true }
  )
  .then(() => {
    console.log("[MongoDB] Connected successfully");
  })
  .catch((err) => {
    console.error("[MongoDB] Connection failed:", err.message);
  });

// Schema lưu thông tin video (chỉ HLS)
const videoSchema = new mongoose.Schema({
  id: { type: String, required: true, unique: true },
  groupId: { type: String, required: true },
  name: String,
  title: String,
  description: String,
  size: Number,
  qualities: [
    {
      resolution: String,
      hls: String,
    },
  ],
  thumbnail: String,
  viewCount: { type: Number, default: 0 },
  commentCount: { type: Number, default: 0 },
  likeCount: { type: Number, default: 0 },
  shareCount: { type: Number, default: 0 },
  createdAt: { type: Date, default: Date.now },
});
const Video = mongoose.model("Video", videoSchema);

app.use(cors({ origin: true }));
app.use(express.json());

// Tạo hàng đợi với Bull
const encodeQueue = new Queue("video-encoding", {
  redis: { host: "127.0.0.1", port: 6379 },
});

// Multer lưu file tạm vào ổ cứng
const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, "uploads/"),
  filename: (req, file, cb) => cb(null, `${uuidv4()}-${file.originalname}`),
});
const upload = multer({
  storage,
  limits: { fileSize: 100 * 1024 * 1024 }, // Giới hạn 100MB
});

// Tạo thư mục uploads và public
try {
  fs.mkdirSync("uploads", { recursive: true });
  fs.mkdirSync("public", { recursive: true });
  console.log("[FS] Created uploads and public directories");
} catch (err) {
  console.error("[FS] Failed to create directories:", err.message);
}

// Tạo file thử nghiệm cho speed-test (~1MB)
const speedTestFilePath = path.join("public", "speed-test-file.bin");
if (!fs.existsSync(speedTestFilePath)) {
  const buffer = Buffer.alloc(1024 * 1024); // 1MB
  fs.writeFileSync(speedTestFilePath, buffer);
  console.log("[FS] Created speed-test file");
}

// Cấu hình các độ phân giải
const QUALITY_CONFIGS = [
  {
    resolution: "1080p",
    height: 1080,
    scale: "1920:1080",
    crf: 23,
    minBitrate: 3000,
  },
  {
    resolution: "720p",
    height: 720,
    scale: "1280:720",
    crf: 26,
    minBitrate: 1500,
  },
  {
    resolution: "480p",
    height: 480,
    scale: "854:480",
    crf: 28,
    minBitrate: 800,
  },
];

// Hàm kiểm tra chất lượng video gốc
function checkVideoQuality(inputPath) {
  return new Promise((resolve, reject) => {
    if (!fs.existsSync(inputPath)) {
      console.error(`[FFprobe] Input file not found: ${inputPath}`);
      return reject(new Error("Input file not found"));
    }
    console.log(`[FFprobe] Checking quality for ${inputPath}`);
    ffmpeg.ffprobe(inputPath, (err, metadata) => {
      if (err) {
        console.error(`[FFprobe] Error: ${err.message}`);
        return reject(err);
      }
      const videoStream = metadata.streams.find(
        (s) => s.codec_type === "video"
      );
      if (!videoStream) {
        console.error("[FFprobe] No video stream found");
        return reject(new Error("No video stream found"));
      }

      const height = videoStream.height;
      const bitrate = videoStream.bit_rate
        ? parseInt(videoStream.bit_rate) / 1000
        : 0; // kbps
      const codec = videoStream.codec_name;

      console.log(
        `[FFprobe] Video: ${height}p, Bitrate: ${bitrate}kbps, Codec: ${codec}`
      );

      if (codec !== "h264") {
        console.error(
          "[FFprobe] Unsupported codec, only H.264 is supported for HLS"
        );
        return reject(
          new Error("Unsupported codec, only H.264 is supported for HLS")
        );
      }

      const validQualities = QUALITY_CONFIGS.filter((q) => {
        return height >= q.height && (!bitrate || bitrate >= q.minBitrate);
      });

      console.log(
        `[FFprobe] Valid qualities: ${validQualities
          .map((q) => q.resolution)
          .join(", ")}`
      );
      resolve(
        validQualities.length > 0
          ? validQualities
          : [QUALITY_CONFIGS[QUALITY_CONFIGS.length - 1]]
      );
    });
  });
}

// Hàm xác định chất lượng video dựa trên tốc độ mạng
function determineVideoQuality(networkSpeed, availableQualities) {
  const speed = parseFloat(networkSpeed) || 3; // Mbps, mặc định 3Mbps
  let resolution = "480p";
  if (speed >= 5) resolution = "1080p";
  else if (speed >= 1) resolution = "720p";

  console.log(`[Quality] Network speed: ${speed}Mbps, Selected: ${resolution}`);

  const quality = availableQualities.find((q) => q.resolution === resolution);
  return quality
    ? quality.resolution
    : availableQualities[availableQualities.length - 1].resolution;
}

// Helper: Encode video to HLS
function encodeToHls(inputPath, outputDir, quality) {
  return new Promise((resolve, reject) => {
    const hlsDir = path.join(outputDir, quality.resolution, "hls");
    try {
      fs.mkdirSync(hlsDir, { recursive: true });
      console.log(`[FFmpeg] Created HLS directory: ${hlsDir}`);
    } catch (err) {
      console.error(`[FFmpeg] Failed to create HLS directory: ${err.message}`);
      return reject(err);
    }
    const cmd = `ffmpeg -i "${inputPath}" -vf scale=${quality.scale},setsar=1:1 -c:v libx264 -preset fast -crf ${quality.crf} -c:a aac -hls_time 4 -hls_playlist_type vod -hls_segment_filename "${hlsDir}/segment-%05d.ts" -threads 2 "${hlsDir}/playlist.m3u8"`;
    console.log(`[FFmpeg] Encoding HLS: ${cmd}`);
    exec(cmd, (err, stdout, stderr) => {
      if (err) {
        console.error(`[FFmpeg] HLS encoding failed: ${err.message}`);
        console.error(`[FFmpeg] stderr: ${stderr}`);
        reject(err);
      } else {
        console.log(
          `[FFmpeg] HLS encoding completed for ${quality.resolution}`
        );
        resolve();
      }
    });
  });
}

// Helper: Extract thumbnail
function extractThumbnail(inputPath, outputDir) {
  return new Promise((resolve, reject) => {
    const thumbPath = path.join(outputDir, "thumbnail.jpg");
    const tryTimes = ["0.1", "0.3", "0.5", "0.7", "1"];
    let tried = 0;

    function tryExtract() {
      console.log(`[FFmpeg] Extracting thumbnail at ${tryTimes[tried]}s`);
      ffmpeg(inputPath)
        .on("end", () => {
          fs.stat(thumbPath, (err, stats) => {
            if (!err && stats.size > 1000) {
              console.log(`[FFmpeg] Thumbnail extracted: ${thumbPath}`);
              resolve(thumbPath);
            } else if (tried < tryTimes.length - 1) {
              tried++;
              tryExtract();
            } else {
              console.error(
                "[FFmpeg] Thumbnail extraction failed or black frame"
              );
              reject(new Error("Thumbnail extraction failed or black frame"));
            }
          });
        })
        .on("error", (err) => {
          console.error(`[FFmpeg] Thumbnail error: ${err.message}`);
          if (tried < tryTimes.length - 1) {
            tried++;
            tryExtract();
          } else {
            reject(err);
          }
        })
        .screenshots({
          count: 1,
          timemarks: [tryTimes[tried]],
          folder: outputDir,
          filename: "thumbnail.jpg",
          size: "640x360",
          quality: 75,
        });
    }
    tryExtract();
  });
}

// Helper: Validate groupId
function validateGroupId(groupId) {
  return /^[a-zA-Z0-9_-]+$/.test(groupId);
}


// Upload video
app.post("/upload", upload.single("video"), async (req, res) => {
  const file = req.file;
  if (!file) {
    console.error("[Upload] No file uploaded");
    return res.status(400).json({ error: "No file uploaded" });
  }

  const { title = "", description = "", groupId = "default" } = req.body;
  console.log(
    `[Upload] Received video: ${file.originalname}, groupId: ${groupId}`
  );

  if (!validateGroupId(groupId)) {
    console.error("[Upload] Invalid groupId format");
    return res.status(400).json({ error: "Invalid groupId format" });
  }

  const id = uuidv4();
  const groupDir = path.join("videos", groupId);
  const videoDir = path.join(groupDir, id);
  try {
    fs.mkdirSync(videoDir, { recursive: true });
    console.log(`[Upload] Created video directory: ${videoDir}`);
  } catch (err) {
    console.error(`[Upload] Failed to create video directory: ${err.message}`);
    return res.status(500).json({
      error: "Failed to create video directory",
      details: err.message,
    });
  }

  const originalPath = path.join(videoDir, "original.mp4");
  try {
    fs.copyFileSync(file.path, originalPath);
    fs.unlinkSync(file.path); // Xóa file tạm
    console.log(`[Upload] Video saved to ${originalPath}`);
  } catch (err) {
    console.error(`[Upload] File operation failed: ${err.message}`);
    return res
      .status(500)
      .json({ error: "File operation failed", details: err.message });
  }

  // Kiểm tra chất lượng video gốc
  let validQualities;
  try {
    validQualities = await checkVideoQuality(originalPath);
    console.log(
      `[Upload] Valid qualities: ${validQualities
        .map((q) => q.resolution)
        .join(", ")}`
    );
  } catch (err) {
    console.error(`[Upload] Failed to check video quality: ${err.message}`);
    return res
      .status(500)
      .json({ error: "Failed to check video quality", details: err.message });
  }

  // Thêm job vào hàng đợi
  try {
    const job = await encodeQueue.add({
      type: "process-video",
      inputPath: originalPath,
      videoDir,
      validQualities,
      id,
      groupId,
      title,
      description,
      name: file.originalname,
      size: fs.statSync(originalPath).size,
    });
    console.log(`[Upload] Job ${job.id} added to queue`);
    res.json({ jobId: job.id, message: "Video processing started" });
  } catch (err) {
    console.error(`[Upload] Failed to add job to queue: ${err.message}`);
    res
      .status(500)
      .json({ error: "Failed to add job to queue", details: err.message });
  }
});

// Xử lý hàng đợi
encodeQueue.process(2, async (job, done) => {
  const start = Date.now();
  console.log(`[Bull] Starting job ${job.id} with data:`, job.data);
  const {
    inputPath,
    videoDir,
    validQualities,
    id,
    groupId,
    title,
    description,
    name,
    size,
  } = job.data;

  try {
    // Kiểm tra file đầu vào
    if (!fs.existsSync(inputPath)) {
      console.error(
        `[Bull] Job ${job.id} - Input file not found: ${inputPath}`
      );
      throw new Error("Input file not found");
    }

    // Trích xuất thumbnail
    let thumbPath;
    try {
      const thumbStart = Date.now();
      thumbPath = await extractThumbnail(inputPath, videoDir);
      console.log(
        `[Bull] Job ${job.id} - Thumbnail extracted: ${thumbPath} in ${
          Date.now() - thumbStart
        }ms`
      );
    } catch (err) {
      console.error(
        `[Bull] Job ${job.id} - Thumbnail extraction failed: ${err.message}`
      );
      throw new Error(`Thumbnail extraction failed: ${err.message}`);
    }

    // Mã hóa HLS
    const qualities = [];
    const errors = [];
    for (const quality of validQualities) {
      try {
        const hlsStart = Date.now();
        await encodeToHls(inputPath, videoDir, quality);
        qualities.push({
          resolution: quality.resolution,
          hls: `/video/${groupId}/${id}/${quality.resolution}/hls/playlist.m3u8`,
        });
        console.log(
          `[Bull] Job ${job.id} - HLS ${
            quality.resolution
          } encoded successfully in ${Date.now() - hlsStart}ms`
        );
      } catch (err) {
        console.error(
          `[Bull] Job ${job.id} - Error encoding ${quality.resolution}: ${err.message}`
        );
        errors.push(`Error encoding ${quality.resolution}: ${err.message}`);
      }
    }

    if (errors.length > 0) {
      console.error(
        `[Bull] Job ${job.id} - Encoding errors: ${errors.join("; ")}`
      );
      throw new Error(`Encoding failed: ${errors.join("; ")}`);
    }

    // Lưu metadata vào MongoDB
    try {
      const mongoStart = Date.now();
      const meta = {
        id,
        groupId,
        name,
        title,
        description,
        size,
        qualities,
        thumbnail: `/video/${groupId}/${id}/thumbnail.jpg`,
        viewCount: 0,
        commentCount: 0,
        likeCount: 0,
        shareCount: 0,
        createdAt: new Date(),
      };
      await Video.create(meta);
      console.log(
        `[Bull] Job ${job.id} - Metadata saved to MongoDB in ${
          Date.now() - mongoStart
        }ms`
      );
    } catch (err) {
      console.error(
        `[Bull] Job ${job.id} - MongoDB save failed: ${err.message}`
      );
      throw new Error(`MongoDB save failed: ${err.message}`);
    }

    // Xóa file MP4 gốc
    try {
      if (fs.existsSync(inputPath)) {
        fs.unlinkSync(inputPath);
        console.log(`[Bull] Job ${job.id} - Original file deleted`);
      }
    } catch (err) {
      console.error(
        `[Bull] Job ${job.id} - File deletion failed: ${err.message}`
      );
      // Không throw lỗi vì xóa file không phải bước quan trọng
    }

    console.log(
      `[Bull] Job ${job.id} completed successfully in ${Date.now() - start}ms`
    );
    done();
  } catch (err) {
    console.error(`[Bull] Job ${job.id} failed: ${err.message}`);
    done(new Error(err.message));
  }
});

// Xử lý lỗi hàng đợi
encodeQueue.on("failed", (job, err) => {
  console.error(`[Bull] Job ${job.id} failed with error: ${err.message}`);
});

// Xử lý job hoàn thành
encodeQueue.on("completed", (job) => {
  console.log(`[Bull] Job ${job.id} completed`);
});

// Get video metadata
app.get("/video/:groupId/:id/meta", async (req, res) => {
  const { groupId, id } = req.params;
  if (!validateGroupId(groupId)) {
    console.error(`[Meta] Invalid groupId format: ${groupId}`);
    return res.status(400).json({ error: "Invalid groupId format" });
  }

  try {
    const video = await Video.findOne({ id, groupId });
    if (!video) {
      console.error(`[Meta] Video not found: ${groupId}/${id}`);
      return res.status(404).json({ error: "Video not found" });
    }
    console.log(`[Meta] Served metadata for ${groupId}/${id}`);
    res.json(video);
  } catch (err) {
    console.error(`[Meta] Error fetching metadata: ${err.message}`);
    res
      .status(500)
      .json({ error: "Error fetching metadata", details: err.message });
  }
});

// List videos by group
app.get("/videos/:groupId", async (req, res) => {
  const { groupId } = req.params;
  if (!validateGroupId(groupId)) {
    console.error(`[Videos] Invalid groupId format: ${groupId}`);
    return res.status(400).json({ error: "Invalid groupId format" });
  }

  try {
    const videos = await Video.find({ groupId });
    console.log(`[Videos] Found ${videos.length} videos for group ${groupId}`);
    res.json(videos);
  } catch (err) {
    console.error(`[Videos] Error fetching videos: ${err.message}`);
    res
      .status(500)
      .json({ error: "Error fetching videos", details: err.message });
  }
});

// List all groups
app.get("/groups", (req, res) => {
  if (!fs.existsSync("videos")) {
    console.log("[Groups] No videos directory found");
    return res.json([]);
  }

  try {
    const groups = fs
      .readdirSync("videos")
      .filter((f) => fs.statSync(path.join("videos", f)).isDirectory());
    console.log(`[Groups] Found ${groups.length} groups`);
    res.json(groups);
  } catch (err) {
    console.error(`[Groups] Error reading groups: ${err.message}`);
    res
      .status(500)
      .json({ error: "Error reading groups", details: err.message });
  }
});

app.get("/videos", async (req, res) => {
  try {
    const videos = await Video.find({});
    console.log(`[Videos] Found ${videos.length} videos`);
    res.json(videos);
  } catch (err) {
    console.error(`[Videos] Error fetching all videos: ${err.message}`);
    res
      .status(500)
      .json({ error: "Error fetching videos", details: err.message });
  }
});

// Serve HLS playlist
app.get("/video/:groupId/:id/:resolution/hls/playlist.m3u8", (req, res) => {
  const { groupId, id, resolution } = req.params;
  if (!validateGroupId(groupId)) {
    console.error(`[HLS] Invalid groupId format: ${groupId}`);
    return res.status(400).json({ error: "Invalid groupId format" });
  }
  if (!["1080p", "720p", "480p"].includes(resolution)) {
    console.error(`[HLS] Invalid resolution: ${resolution}`);
    return res.status(400).json({ error: "Invalid resolution" });
  }
  const playlistPath = path.join(
    "videos",
    groupId,
    id,
    resolution,
    "hls",
    "playlist.m3u8"
  );
  if (!fs.existsSync(playlistPath)) {
    console.error(`[HLS] Playlist not found: ${playlistPath}`);
    return res.status(404).json({ error: "Playlist not found" });
  }
  try {
    const stat = fs.statSync(playlistPath);
    const fileSize = stat.size;
    const range = req.headers.range;
    res.setHeader("Content-Type", "application/vnd.apple.mpegurl");
    res.setHeader("Accept-Ranges", "bytes");
    if (range) {
      const parts = range.replace(/bytes=/, "").split("-");
      const start = parseInt(parts[0], 10);
      const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;
      const chunkSize = end - start + 1;
      const file = fs.createReadStream(playlistPath, { start, end });
      res.writeHead(206, {
        "Content-Range": `bytes ${start}-${end}/${fileSize}`,
        "Content-Length": chunkSize,
        "Content-Type": "application/vnd.apple.mpegurl",
        "Accept-Ranges": "bytes",
      });
      file.pipe(res);
    } else {
      res.writeHead(200, {
        "Content-Length": fileSize,
        "Content-Type": "application/vnd.apple.mpegurl",
        "Accept-Ranges": "bytes",
      });
      fs.createReadStream(playlistPath).pipe(res);
    }
  } catch (err) {
    console.error(`[HLS] Error serving playlist: ${err.message}`);
    res
      .status(500)
      .json({ error: "Error serving playlist", details: err.message });
  }
});

// Serve HLS segment
app.get("/video/:groupId/:id/:resolution/hls/:segment", (req, res) => {
  const { groupId, id, resolution, segment } = req.params;
  if (!validateGroupId(groupId)) {
    console.error(`[HLS] Invalid groupId format: ${groupId}`);
    return res.status(400).json({ error: "Invalid groupId format" });
  }
  if (!["1080p", "720p", "480p"].includes(resolution)) {
    console.error(`[HLS] Invalid resolution: ${resolution}`);
    return res.status(400).json({ error: "Invalid resolution" });
  }
  if (!segment.endsWith(".ts")) {
    console.error(`[HLS] Invalid segment: ${segment}`);
    return res.status(400).json({ error: "Invalid segment" });
  }
  const segmentPath = path.join(
    "videos",
    groupId,
    id,
    resolution,
    "hls",
    segment
  );
  if (!fs.existsSync(segmentPath)) {
    console.error(`[HLS] Segment not found: ${segmentPath}`);
    return res.status(404).json({ error: "Segment not found" });
  }
  try {
    const stat = fs.statSync(segmentPath);
    const fileSize = stat.size;
    const range = req.headers.range;
    res.setHeader("Content-Type", "video/MP2T");
    res.setHeader("Accept-Ranges", "bytes");
    if (range) {
      const parts = range.replace(/bytes=/, "").split("-");
      const start = parseInt(parts[0], 10);
      const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;
      const chunkSize = end - start + 1;
      const file = fs.createReadStream(segmentPath, { start, end });
      res.writeHead(206, {
        "Content-Range": `bytes ${start}-${end}/${fileSize}`,
        "Content-Length": chunkSize,
        "Content-Type": "video/MP2T",
        "Accept-Ranges": "bytes",
      });
      file.pipe(res);
    } else {
      res.writeHead(200, {
        "Content-Length": fileSize,
        "Content-Type": "video/MP2T",
        "Accept-Ranges": "bytes",
      });
      fs.createReadStream(segmentPath).pipe(res);
    }
  } catch (err) {
    console.error(`[HLS] Error serving segment: ${err.message}`);
    res
      .status(500)
      .json({ error: "Error serving segment", details: err.message });
  }
});



// Serve original MP4 (fallback, nhưng thường không còn do đã xóa)
app.get("/video/:groupId/:id/original.mp4", (req, res) => {
  const { groupId, id } = req.params;
  if (!validateGroupId(groupId)) {
    console.error(`[Original] Invalid groupId format: ${groupId}`);
    return res.status(400).json({ error: "Invalid groupId format" });
  }
  const mp4Path = path.join("videos", groupId, id, "original.mp4"); // Sửa lỗi track.join
  if (!fs.existsSync(mp4Path)) {
    console.error(`[Original] Original MP4 not found: ${mp4Path}`);
    return res.status(404).json({
      error: "Original MP4 not found (likely deleted after encoding)",
    });
  }

  try {
    const stat = fs.statSync(mp4Path);
    const fileSize = stat.size;
    const range = req.headers.range;

    if (range) {
      const parts = range.replace(/bytes=/, "").split("-");
      const start = parseInt(parts[0], 10);
      const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;
      const chunkSize = end - start + 1;
      const file = fs.createReadStream(mp4Path, { start, end });
      res.writeHead(206, {
        "Content-Range": `bytes ${start}-${end}/${fileSize}`,
        "Accept-Ranges": "bytes",
        "Content-Length": chunkSize,
        "Content-Type": "video/mp4",
      });
      file.pipe(res);
    } else {
      res.writeHead(200, {
        "Content-Length": fileSize,
        "Content-Type": "video/mp4",
        "Accept-Ranges": "bytes",
      });
      fs.createReadStream(mp4Path).pipe(res);
    }
  } catch (err) {
    console.error(`[Original] Error serving MP4: ${err.message}`);
    res.status(500).json({ error: "Error serving MP4", details: err.message });
  }
});

// Serve thumbnail
app.get("/video/:groupId/:id/thumbnail.jpg", (req, res) => {
  const { groupId, id } = req.params;
  if (!validateGroupId(groupId)) {
    console.error(`[Thumbnail] Invalid groupId format: ${groupId}`);
    return res.status(400).json({ error: "Invalid groupId format" });
  }
  const thumbPath = path.join("videos", groupId, id, "thumbnail.jpg");
  if (!fs.existsSync(thumbPath)) {
    console.error(`[Thumbnail] Thumbnail not found: ${thumbPath}`);
    return res.status(404).json({ error: "Thumbnail not found" });
  }
  console.log(`[Thumbnail] Serving thumbnail: ${thumbPath}`);
  try {
    res.setHeader("Content-Type", "image/jpeg");
    fs.createReadStream(thumbPath).pipe(res);
  } catch (err) {
    console.error(`[Thumbnail] Error serving thumbnail: ${err.message}`);
    res
      .status(500)
      .json({ error: "Error serving thumbnail", details: err.message });
  }
});

// Welcome endpoint
app.get("/", (req, res) => {
  console.log("[Root] Welcome endpoint accessed");
  res.send("Welcome to Video Streaming API");
});

app.listen(PORT, () => {
  console.log(`Video streaming backend running on http://localhost:${PORT}`);
});
