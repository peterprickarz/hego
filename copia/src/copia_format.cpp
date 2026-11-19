#include "copia_format.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/hashing_context.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <algorithm>
#include <cmath>
#include <numeric>

using namespace godot;

namespace Copia {

std::string to_std(const String &p_value) {
    CharString utf8 = p_value.utf8();
    return std::string(utf8.get_data(), size_t(utf8.length()));
}

String to_godot(const std::string &p_value) {
    return String::utf8(p_value.data(), int64_t(p_value.size()));
}

static PackedByteArray to_packed(const uint8_t *p_data, size_t p_size) {
    PackedByteArray packed;
    packed.resize(int64_t(p_size));
    if (p_size > 0) {
        std::memcpy(packed.ptrw(), p_data, p_size);
    }
    return packed;
}

bool compress_block(const uint8_t *p_data, size_t p_size, Bytes &r_out) {
    r_out.clear();
    if (p_size == 0) {
        return true;
    }
    PackedByteArray compressed = to_packed(p_data, p_size).compress(FileAccess::COMPRESSION_ZSTD);
    if (compressed.size() == 0) {
        return false;
    }
    r_out.assign(compressed.ptr(), compressed.ptr() + compressed.size());
    return true;
}

bool decompress_block(const uint8_t *p_data, size_t p_size, size_t p_raw_size, Bytes &r_out) {
    r_out.clear();
    if (p_raw_size == 0) {
        return p_size == 0;
    }
    if (p_size == 0) {
        return false;
    }
    PackedByteArray raw = to_packed(p_data, p_size).decompress(int64_t(p_raw_size), FileAccess::COMPRESSION_ZSTD);
    if (size_t(raw.size()) != p_raw_size) {
        return false;
    }
    r_out.assign(raw.ptr(), raw.ptr() + raw.size());
    return true;
}

Hash sha256(const uint8_t *p_data, size_t p_size) {
    Ref<HashingContext> context;
    context.instantiate();
    context->start(HashingContext::HASH_SHA256);
    // HashingContext takes PackedByteArrays; feed large inputs in 16 MiB chunks.
    const size_t chunk = size_t(16) << 20;
    for (size_t offset = 0; offset < p_size; offset += chunk) {
        context->update(to_packed(p_data + offset, std::min(chunk, p_size - offset)));
    }
    PackedByteArray digest = context->finish();
    Hash hash{};
    if (digest.size() == 32) {
        std::memcpy(hash.data(), digest.ptr(), 32);
    }
    return hash;
}

std::string hash_hex(const Hash &p_hash) {
    static const char *digits = "0123456789abcdef";
    std::string hex;
    hex.reserve(64);
    for (uint8_t byte : p_hash) {
        hex.push_back(digits[byte >> 4]);
        hex.push_back(digits[byte & 15]);
    }
    return hex;
}

bool read_file(const String &p_path, Bytes &r_out) {
    r_out.clear();
    Ref<FileAccess> file = FileAccess::open(p_path, FileAccess::READ);
    if (file.is_null()) {
        return false;
    }
    uint64_t length = file->get_length();
    r_out.resize(size_t(length));
    if (length > 0 && file->get_buffer(r_out.data(), length) != length) {
        r_out.clear();
        return false;
    }
    return true;
}

bool read_file_prefix(const String &p_path, size_t p_size, Bytes &r_out) {
    r_out.clear();
    Ref<FileAccess> file = FileAccess::open(p_path, FileAccess::READ);
    if (file.is_null()) {
        return false;
    }
    uint64_t length = std::min<uint64_t>(file->get_length(), p_size);
    r_out.resize(size_t(length));
    if (length > 0 && file->get_buffer(r_out.data(), length) != length) {
        r_out.clear();
        return false;
    }
    return true;
}

bool write_file_atomic(const String &p_path, const Bytes &p_data, std::string &r_error) {
    String directory = p_path.get_base_dir();
    if (!DirAccess::dir_exists_absolute(directory) && DirAccess::make_dir_recursive_absolute(directory) != OK) {
        r_error = "cannot create directory " + to_std(directory);
        return false;
    }
    String temporary = p_path + String(".tmp");
    {
        Ref<FileAccess> file = FileAccess::open(temporary, FileAccess::WRITE);
        if (file.is_null()) {
            r_error = "cannot write " + to_std(temporary);
            return false;
        }
        if (!p_data.empty()) {
            file->store_buffer(p_data.data(), p_data.size());
        }
        bool failed = file->get_error() != OK;
        file->close();
        if (failed) {
            DirAccess::remove_absolute(temporary);
            r_error = "write failed for " + to_std(temporary);
            return false;
        }
    }
    if (DirAccess::rename_absolute(temporary, p_path) != OK) {
        DirAccess::remove_absolute(temporary);
        r_error = "cannot rename " + to_std(temporary) + " to " + to_std(p_path);
        return false;
    }
    return true;
}

bool remove_file(const String &p_path) {
    return DirAccess::remove_absolute(p_path) == OK;
}

bool file_exists(const String &p_path) {
    return FileAccess::file_exists(p_path);
}

bool valid_set_name(const std::string &p_name) {
    if (p_name.empty() || p_name.size() > 64) {
        return false;
    }
    for (char c : p_name) {
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) {
            return false;
        }
    }
    return true;
}

std::string cell_name(int32_t p_cx, int32_t p_cz) {
    return std::to_string(p_cx) + "_" + std::to_string(p_cz);
}

static bool parse_int(const std::string &p_text, int32_t &r_value) {
    if (p_text.empty() || p_text.size() > 11) {
        return false;
    }
    size_t start = p_text[0] == '-' ? 1 : 0;
    if (start == p_text.size()) {
        return false;
    }
    int64_t value = 0;
    for (size_t i = start; i < p_text.size(); i++) {
        char c = p_text[i];
        if (c < '0' || c > '9') {
            return false;
        }
        value = value * 10 + (c - '0');
    }
    if (start == 1) {
        value = -value;
    }
    if (value < INT32_MIN || value > INT32_MAX) {
        return false;
    }
    // Only the canonical spelling, so one cell has one file name.
    if (std::to_string(value) != p_text) {
        return false;
    }
    r_value = int32_t(value);
    return true;
}

bool parse_cell_name(const std::string &p_file, const char *p_extension, int32_t &r_cx, int32_t &r_cz) {
    size_t extension_length = std::strlen(p_extension);
    if (p_file.size() <= extension_length || p_file.compare(p_file.size() - extension_length, extension_length, p_extension) != 0) {
        return false;
    }
    std::string stem = p_file.substr(0, p_file.size() - extension_length);
    size_t separator = stem.find('_', 1);
    if (separator == std::string::npos) {
        return false;
    }
    return parse_int(stem.substr(0, separator), r_cx) && parse_int(stem.substr(separator + 1), r_cz);
}

bool cell_index(double p_value, double p_size, int32_t &r_index) {
    double index = std::floor(p_value / p_size);
    if (!std::isfinite(index) || index < double(INT32_MIN) || index > double(INT32_MAX)) {
        return false;
    }
    r_index = int32_t(index);
    return true;
}

int64_t floor_div(int64_t p_value, int64_t p_divisor) {
    int64_t quotient = p_value / p_divisor;
    if ((p_value % p_divisor != 0) && ((p_value < 0) != (p_divisor < 0))) {
        quotient--;
    }
    return quotient;
}

size_t row_stride(const std::vector<ExtraColumn> &p_extras) {
    size_t stride = ROW_FIXED;
    for (const ExtraColumn &column : p_extras) {
        stride += column.bytes();
    }
    return stride;
}

bool row_has_none(const uint8_t *p_row, size_t p_offset) {
    uint32_t bits;
    std::memcpy(&bits, p_row + p_offset, 4);
    return bits == NONE_BITS;
}

void canonical_sort(Bytes &r_rows, uint32_t p_count, size_t p_stride) {
    if (p_count < 2) {
        return;
    }
    std::vector<uint32_t> order(p_count);
    std::iota(order.begin(), order.end(), 0u);
    const uint8_t *rows = r_rows.data();
    std::sort(order.begin(), order.end(), [rows, p_stride](uint32_t a, uint32_t b) {
        return std::memcmp(rows + size_t(a) * p_stride, rows + size_t(b) * p_stride, p_stride) < 0;
    });
    Bytes sorted(r_rows.size());
    for (uint32_t i = 0; i < p_count; i++) {
        std::memcpy(sorted.data() + size_t(i) * p_stride, rows + size_t(order[i]) * p_stride, p_stride);
    }
    r_rows.swap(sorted);
}

Bytes relayout_rows(const Bytes &p_rows, uint32_t p_count, const std::vector<ExtraColumn> &p_from,
        const std::vector<ExtraColumn> &p_to) {
    size_t from_stride = row_stride(p_from);
    size_t to_stride = row_stride(p_to);
    // For each target column, its byte offset in the source row or SIZE_MAX if absent.
    std::vector<size_t> source(p_to.size(), SIZE_MAX);
    std::vector<size_t> target(p_to.size(), 0);
    size_t to_offset = ROW_FIXED;
    for (size_t i = 0; i < p_to.size(); i++) {
        target[i] = to_offset;
        to_offset += p_to[i].bytes();
        size_t from_offset = ROW_FIXED;
        for (const ExtraColumn &column : p_from) {
            if (column.name == p_to[i].name) {
                source[i] = from_offset;
                break;
            }
            from_offset += column.bytes();
        }
    }
    Bytes rows(size_t(p_count) * to_stride, 0);
    for (uint32_t r = 0; r < p_count; r++) {
        const uint8_t *in = p_rows.data() + size_t(r) * from_stride;
        uint8_t *out = rows.data() + size_t(r) * to_stride;
        std::memcpy(out, in, ROW_FIXED);
        for (size_t i = 0; i < p_to.size(); i++) {
            if (source[i] != SIZE_MAX) {
                std::memcpy(out + target[i], in + source[i], p_to[i].bytes());
            }
        }
    }
    return rows;
}

// The columns of one object's points as stored in its section block.
static void rows_to_block(const ObjectRows &p_object, const std::vector<ExtraColumn> &p_extras, uint32_t p_flags,
        Bytes &r_block) {
    size_t stride = row_stride(p_extras);
    size_t n = p_object.count;
    r_block.clear();
    r_block.reserve(n * stride);
    auto column = [&](size_t p_offset, size_t p_bytes) {
        size_t start = r_block.size();
        r_block.resize(start + n * p_bytes);
        uint8_t *out = r_block.data() + start;
        for (size_t i = 0; i < n; i++) {
            std::memcpy(out + i * p_bytes, p_object.rows.data() + i * stride + p_offset, p_bytes);
        }
    };
    column(ROW_TRANSFORM, 48);
    if (p_flags & COLUMN_COLOR) {
        column(ROW_COLOR, 16);
    }
    if (p_flags & COLUMN_CUSTOM) {
        column(ROW_CUSTOM, 16);
    }
    if (p_flags & COLUMN_KEEP) {
        column(ROW_KEEP, 4);
    }
    size_t offset = ROW_FIXED;
    for (const ExtraColumn &extra : p_extras) {
        column(offset, extra.bytes());
        offset += extra.bytes();
    }
}

static size_t block_size(uint32_t p_count, const std::vector<ExtraColumn> &p_extras, uint32_t p_flags) {
    size_t per_point = 48;
    if (p_flags & COLUMN_COLOR) {
        per_point += 16;
    }
    if (p_flags & COLUMN_CUSTOM) {
        per_point += 16;
    }
    if (p_flags & COLUMN_KEEP) {
        per_point += 4;
    }
    for (const ExtraColumn &extra : p_extras) {
        per_point += extra.bytes();
    }
    return per_point * p_count;
}

bool encode_set_file(SetFile &r_file, Bytes &r_out) {
    const size_t stride = row_stride(r_file.extras);
    const float one = 1.0f;
    uint32_t flags = 0;
    uint64_t point_count = 0;
    for (const ObjectRows &object : r_file.objects) {
        point_count += object.count;
        for (uint32_t i = 0; i < object.count; i++) {
            const uint8_t *row = object.rows.data() + size_t(i) * stride;
            if (!row_has_none(row, ROW_COLOR)) {
                flags |= COLUMN_COLOR;
            }
            if (!row_has_none(row, ROW_CUSTOM)) {
                flags |= COLUMN_CUSTOM;
            }
            if (std::memcmp(row + ROW_KEEP, &one, 4) != 0) {
                flags |= COLUMN_KEEP;
            }
        }
    }
    r_file.flags = flags;
    r_file.point_count = uint32_t(point_count);

    ByteWriter tables;
    tables.u32(uint32_t(r_file.objects.size()));
    for (const ObjectRows &object : r_file.objects) {
        tables.str(object.path);
    }
    tables.u32(uint32_t(r_file.extras.size()));
    for (const ExtraColumn &extra : r_file.extras) {
        tables.str(extra.name);
        tables.u8(extra.type);
        tables.u8(extra.width);
    }

    ByteWriter canonical;
    canonical.u32(flags);
    canonical.raw(tables.data.data(), tables.data.size());
    ByteWriter sections;
    Bytes block;
    Bytes compressed;
    for (const ObjectRows &object : r_file.objects) {
        rows_to_block(object, r_file.extras, flags, block);
        canonical.u32(object.count);
        canonical.raw(block.data(), block.size());
        if (!compress_block(block.data(), block.size(), compressed)) {
            return false;
        }
        sections.u32(object.count);
        sections.u32(uint32_t(block.size()));
        sections.u32(uint32_t(compressed.size()));
        sections.raw(compressed.data(), compressed.size());
    }
    r_file.hash = sha256(canonical.data.data(), canonical.data.size());

    ByteWriter out;
    out.raw("CPST", 4);
    out.u32(SET_FORMAT_VERSION);
    out.i32(r_file.cx);
    out.i32(r_file.cz);
    out.f32(r_file.cell_size);
    out.u32(r_file.point_count);
    out.u32(flags);
    out.raw(r_file.hash.data(), 32);
    out.raw(tables.data.data(), tables.data.size());
    out.raw(sections.data.data(), sections.data.size());
    r_out.swap(out.data);
    return true;
}

bool decode_set_file(const Bytes &p_data, SetFile &r_file, bool p_header_only, std::string &r_error) {
    ByteReader in(p_data.data(), p_data.size());
    char magic[4];
    in.raw(magic, 4);
    uint32_t version = in.u32();
    if (!in.ok() || std::memcmp(magic, "CPST", 4) != 0) {
        r_error = "not a Copia set file";
        return false;
    }
    if (version != SET_FORMAT_VERSION) {
        r_error = "unsupported set file version " + std::to_string(version);
        return false;
    }
    r_file.cx = in.i32();
    r_file.cz = in.i32();
    r_file.cell_size = in.f32();
    r_file.point_count = in.u32();
    r_file.flags = in.u32();
    in.raw(r_file.hash.data(), 32);
    if (!in.ok()) {
        r_error = "truncated set file header";
        return false;
    }
    if (p_header_only) {
        return true;
    }
    uint32_t object_count = in.u32();
    if (!in.ok() || object_count > p_data.size()) {
        r_error = "corrupt object table";
        return false;
    }
    r_file.objects.assign(object_count, ObjectRows());
    for (ObjectRows &object : r_file.objects) {
        object.path = in.str();
    }
    uint32_t extra_count = in.u32();
    if (!in.ok() || extra_count > p_data.size()) {
        r_error = "corrupt extra column table";
        return false;
    }
    r_file.extras.assign(extra_count, ExtraColumn());
    for (ExtraColumn &extra : r_file.extras) {
        extra.name = in.str();
        extra.type = in.u8();
        extra.width = in.u8();
        bool valid = (extra.type == EXTRA_INT32 && extra.width == 1) || (extra.type == EXTRA_FLOAT32 && (extra.width == 1 || extra.width == 3));
        if (!valid) {
            r_error = "unknown extra column kind";
            return false;
        }
    }
    if (!in.ok()) {
        r_error = "truncated tables";
        return false;
    }
    const size_t stride = row_stride(r_file.extras);
    const float one = 1.0f;
    uint64_t total = 0;
    Bytes block;
    for (ObjectRows &object : r_file.objects) {
        uint32_t count = in.u32();
        uint32_t raw_size = in.u32();
        uint32_t compressed_size = in.u32();
        const uint8_t *compressed = in.take(compressed_size);
        if (!in.ok() || count == 0 || raw_size != block_size(count, r_file.extras, r_file.flags)) {
            r_error = "corrupt section of " + object.path;
            return false;
        }
        if (!decompress_block(compressed, compressed_size, raw_size, block)) {
            r_error = "cannot decompress section of " + object.path;
            return false;
        }
        object.count = count;
        object.rows.assign(size_t(count) * stride, 0);
        size_t at = 0;
        auto column = [&](size_t p_offset, size_t p_bytes) {
            for (uint32_t i = 0; i < count; i++) {
                std::memcpy(object.rows.data() + size_t(i) * stride + p_offset, block.data() + at + size_t(i) * p_bytes, p_bytes);
            }
            at += size_t(count) * p_bytes;
        };
        auto fill = [&](size_t p_offset, const void *p_value, size_t p_bytes, size_t p_repeat) {
            for (uint32_t i = 0; i < count; i++) {
                for (size_t k = 0; k < p_repeat; k++) {
                    std::memcpy(object.rows.data() + size_t(i) * stride + p_offset + k * p_bytes, p_value, p_bytes);
                }
            }
        };
        column(ROW_TRANSFORM, 48);
        if (r_file.flags & COLUMN_COLOR) {
            column(ROW_COLOR, 16);
        } else {
            fill(ROW_COLOR, &NONE_BITS, 4, 4);
        }
        if (r_file.flags & COLUMN_CUSTOM) {
            column(ROW_CUSTOM, 16);
        } else {
            fill(ROW_CUSTOM, &NONE_BITS, 4, 4);
        }
        if (r_file.flags & COLUMN_KEEP) {
            column(ROW_KEEP, 4);
        } else {
            fill(ROW_KEEP, &one, 4, 1);
        }
        size_t offset = ROW_FIXED;
        for (const ExtraColumn &extra : r_file.extras) {
            column(offset, extra.bytes());
            offset += extra.bytes();
        }
        total += count;
    }
    if (!in.ok() || total != r_file.point_count) {
        r_error = "point count does not match the header";
        return false;
    }
    return true;
}

int worker_thread_count() {
    ProjectSettings *settings = ProjectSettings::get_singleton();
    int configured = settings ? int(settings->get_setting("threading/worker_pool/max_threads", -1)) : -1;
    return configured > 0 ? configured : OS::get_singleton()->get_processor_count();
}

void parallel_for(int64_t p_count, const std::function<void(int64_t)> &p_function) {
    if (p_count <= 0) {
        return;
    }
    if (p_count == 1) {
        p_function(0);
        return;
    }
    Ref<CopiaParallelJob> job;
    job.instantiate();
    job->function = p_function;
    WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
    int64_t group = pool->add_group_task(callable_mp(job.ptr(), &CopiaParallelJob::run), int32_t(p_count), -1, true,
            "Copia");
    pool->wait_for_group_task_completion(group);
}

} // namespace Copia
