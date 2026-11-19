#ifndef COPIA_FORMAT_H
#define COPIA_FORMAT_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

// Shared pieces of Copia's file formats: byte buffers, Zstandard blocks, SHA-256, file I/O
// with temporary files, set file encoding and the worker pool helper. All functions here are
// safe to call from worker threads; none touches a RenderingServer, a PhysicsServer or a
// Godot resource. Every format is little-endian (the only byte order Copia builds for).

namespace Copia {

using Bytes = std::vector<uint8_t>;
using Hash = std::array<uint8_t, 32>;

constexpr uint32_t SET_FORMAT_VERSION = 1;
constexpr uint32_t CELL_FORMAT_VERSION = 1;
constexpr size_t SET_HEADER_SIZE = 60;
constexpr size_t CELL_HEADER_SIZE = 32;
constexpr size_t BATCH_RECORD_SIZE = 72;
constexpr int FLOATS_PER_INSTANCE = 20;

// Set file column flags: which optional columns a file stores.
constexpr uint32_t COLUMN_COLOR = 1;
constexpr uint32_t COLUMN_CUSTOM = 2;
constexpr uint32_t COLUMN_KEEP = 4;

// In-memory row of one point: transform (12 f32), colour (4 f32), custom (4 f32), keep (f32),
// then the extra columns in name order. Its bytes are the canonical sort key.
constexpr size_t ROW_TRANSFORM = 0;
constexpr size_t ROW_COLOR = 48;
constexpr size_t ROW_CUSTOM = 64;
constexpr size_t ROW_KEEP = 80;
constexpr size_t ROW_FIXED = 84;
// "Carries none" marker for colour and custom data: a quiet NaN in all four components.
constexpr uint32_t NONE_BITS = 0x7FC00000u;

enum ExtraType : uint8_t {
    EXTRA_INT32 = 0,
    EXTRA_FLOAT32 = 1,
};

struct ExtraColumn {
    std::string name;
    uint8_t type = EXTRA_FLOAT32;
    uint8_t width = 1;
    size_t bytes() const { return size_t(width) * 4; }
    bool same_kind(const ExtraColumn &p_other) const { return type == p_other.type && width == p_other.width; }
};

struct ObjectRows {
    std::string path;
    Bytes rows;
    uint32_t count = 0;
};

struct SetFile {
    int32_t cx = 0;
    int32_t cz = 0;
    float cell_size = 0.0f;
    uint32_t flags = 0;
    uint32_t point_count = 0;
    Hash hash{};
    std::vector<ExtraColumn> extras; // sorted by name
    std::vector<ObjectRows> objects; // sorted by path, rows in canonical order
};

class ByteWriter {
public:
    Bytes data;
    void u8(uint8_t p_value) { data.push_back(p_value); }
    void u32(uint32_t p_value) { raw(&p_value, 4); }
    void i32(int32_t p_value) { raw(&p_value, 4); }
    void u64(uint64_t p_value) { raw(&p_value, 8); }
    void f32(float p_value) { raw(&p_value, 4); }
    void str(const std::string &p_value) {
        u32(uint32_t(p_value.size()));
        raw(p_value.data(), p_value.size());
    }
    void raw(const void *p_data, size_t p_size) {
        const uint8_t *bytes = static_cast<const uint8_t *>(p_data);
        data.insert(data.end(), bytes, bytes + p_size);
    }
};

class ByteReader {
public:
    ByteReader(const uint8_t *p_data, size_t p_size) : data(p_data), size(p_size) {}
    bool ok() const { return !failed; }
    size_t position() const { return pos; }
    uint8_t u8() { uint8_t v = 0; raw(&v, 1); return v; }
    uint32_t u32() { uint32_t v = 0; raw(&v, 4); return v; }
    int32_t i32() { int32_t v = 0; raw(&v, 4); return v; }
    uint64_t u64() { uint64_t v = 0; raw(&v, 8); return v; }
    float f32() { float v = 0; raw(&v, 4); return v; }
    std::string str() {
        uint32_t length = u32();
        if (failed || length > size - pos) {
            failed = true;
            return std::string();
        }
        std::string value(reinterpret_cast<const char *>(data + pos), length);
        pos += length;
        return value;
    }
    void raw(void *p_out, size_t p_size) {
        if (failed || p_size > size - pos) {
            failed = true;
            std::memset(p_out, 0, p_size);
            return;
        }
        std::memcpy(p_out, data + pos, p_size);
        pos += p_size;
    }
    const uint8_t *take(size_t p_size) {
        if (failed || p_size > size - pos) {
            failed = true;
            return nullptr;
        }
        const uint8_t *at = data + pos;
        pos += p_size;
        return at;
    }

private:
    const uint8_t *data;
    size_t size;
    size_t pos = 0;
    bool failed = false;
};

std::string to_std(const godot::String &p_value);
godot::String to_godot(const std::string &p_value);

bool compress_block(const uint8_t *p_data, size_t p_size, Bytes &r_out);
bool decompress_block(const uint8_t *p_data, size_t p_size, size_t p_raw_size, Bytes &r_out);
Hash sha256(const uint8_t *p_data, size_t p_size);
std::string hash_hex(const Hash &p_hash);

bool read_file(const godot::String &p_path, Bytes &r_out);
bool read_file_prefix(const godot::String &p_path, size_t p_size, Bytes &r_out);
// Writes to "<path>.tmp" and renames it over p_path.
bool write_file_atomic(const godot::String &p_path, const Bytes &p_data, std::string &r_error);
bool remove_file(const godot::String &p_path);
bool file_exists(const godot::String &p_path);

// Set names: 1 to 64 characters of a-z, 0-9 and '_'.
bool valid_set_name(const std::string &p_name);
std::string cell_name(int32_t p_cx, int32_t p_cz);
// Parses "<cx>_<cz><extension>"; false for any other name.
bool parse_cell_name(const std::string &p_file, const char *p_extension, int32_t &r_cx, int32_t &r_cz);
// Floor of p_value / p_size as a cell index; false when not finite or out of int32 range.
bool cell_index(double p_value, double p_size, int32_t &r_index);
int64_t floor_div(int64_t p_value, int64_t p_divisor);

size_t row_stride(const std::vector<ExtraColumn> &p_extras);
bool row_has_none(const uint8_t *p_row, size_t p_offset);
// Sorts rows by their bytes (memcmp), the canonical order.
void canonical_sort(Bytes &r_rows, uint32_t p_count, size_t p_stride);
// Copies rows from one extra-column layout into another; missing columns are zero.
Bytes relayout_rows(const Bytes &p_rows, uint32_t p_count, const std::vector<ExtraColumn> &p_from,
        const std::vector<ExtraColumn> &p_to);

// Fills flags, point_count and hash from p_file's rows (which must be sorted) and returns the
// file bytes. False only if compression fails.
bool encode_set_file(SetFile &r_file, Bytes &r_out);
// Decodes a set file. With p_header_only only the 60-byte header is read.
bool decode_set_file(const Bytes &p_data, SetFile &r_file, bool p_header_only, std::string &r_error);

// Runs p_function(0 .. p_count - 1) on the WorkerThreadPool and waits for it.
void parallel_for(int64_t p_count, const std::function<void(int64_t)> &p_function);
int worker_thread_count();

// Holds the function a WorkerThreadPool group task runs (internal class, not exposed).
class CopiaParallelJob : public godot::RefCounted {
    GDCLASS(CopiaParallelJob, godot::RefCounted)

public:
    std::function<void(int64_t)> function;
    void run(uint32_t p_index) { function(int64_t(p_index)); }

protected:
    static void _bind_methods() {}
};

} // namespace Copia

#endif // COPIA_FORMAT_H
