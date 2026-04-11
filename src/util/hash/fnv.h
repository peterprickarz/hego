#ifndef HEGO_UTIL_HASH_FNV_H
#define HEGO_UTIL_HASH_FNV_H

#include <cstddef>
#include <cstdint>
#include <cstring>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace HEGo::Util::Hash
{

constexpr uint64_t FNV_OFFSET = 14695981039346656037ULL;
constexpr uint64_t FNV_PRIME = 1099511628211ULL;

inline uint64_t fnv1a(const void *data, size_t size, uint64_t hash = FNV_OFFSET)
{
	const uint8_t *bytes = static_cast<const uint8_t *>(data);
	for (size_t i = 0; i < size; ++i)
	{
		hash ^= bytes[i];
		hash *= FNV_PRIME;
	}
	return hash;
}

inline uint64_t hash_combine(uint64_t hash, uint64_t value)
{
	return fnv1a(&value, sizeof(value), hash);
}

inline uint64_t hash_float(float v, uint64_t hash = FNV_OFFSET)
{
	return fnv1a(&v, sizeof(v), hash);
}

inline uint64_t hash_int(int v, uint64_t hash = FNV_OFFSET)
{
	return fnv1a(&v, sizeof(v), hash);
}

inline uint64_t hash_transform(const godot::Transform3D &xform, uint64_t hash = FNV_OFFSET)
{
	const godot::Basis &b = xform.basis;
	hash = fnv1a(&b.rows[0].x, sizeof(float) * 3, hash);
	hash = fnv1a(&b.rows[1].x, sizeof(float) * 3, hash);
	hash = fnv1a(&b.rows[2].x, sizeof(float) * 3, hash);
	hash = fnv1a(&xform.origin.x, sizeof(float) * 3, hash);
	return hash;
}

inline uint64_t hash_packed_vector3(const godot::PackedVector3Array &arr, uint64_t hash = FNV_OFFSET)
{
	int size = arr.size();
	hash = hash_combine(hash, static_cast<uint64_t>(size));
	if (size > 0)
	{
		hash = fnv1a(arr.ptr(), size * sizeof(godot::Vector3), hash);
	}
	return hash;
}

inline uint64_t hash_packed_color(const godot::PackedColorArray &arr, uint64_t hash = FNV_OFFSET)
{
	int size = arr.size();
	hash = hash_combine(hash, static_cast<uint64_t>(size));
	if (size > 0)
	{
		hash = fnv1a(arr.ptr(), size * sizeof(godot::Color), hash);
	}
	return hash;
}

inline uint64_t hash_packed_int32(const godot::PackedInt32Array &arr, uint64_t hash = FNV_OFFSET)
{
	int size = arr.size();
	hash = hash_combine(hash, static_cast<uint64_t>(size));
	if (size > 0)
	{
		hash = fnv1a(arr.ptr(), size * sizeof(int32_t), hash);
	}
	return hash;
}

inline uint64_t hash_packed_byte(const godot::PackedByteArray &arr, uint64_t hash = FNV_OFFSET)
{
	int size = arr.size();
	hash = hash_combine(hash, static_cast<uint64_t>(size));
	if (size > 0)
	{
		hash = fnv1a(arr.ptr(), size, hash);
	}
	return hash;
}

inline uint64_t hash_string(const godot::String &s, uint64_t hash = FNV_OFFSET)
{
	godot::CharString utf8 = s.utf8();
	int len = utf8.length();
	hash = hash_combine(hash, static_cast<uint64_t>(len));
	if (len > 0)
	{
		hash = fnv1a(utf8.get_data(), len, hash);
	}
	return hash;
}

// Forward declarations for mutual recursion
inline uint64_t hash_variant(const godot::Variant &v, uint64_t hash = FNV_OFFSET);
inline uint64_t hash_dictionary(const godot::Dictionary &d, uint64_t hash = FNV_OFFSET);
inline uint64_t hash_array(const godot::Array &arr, uint64_t hash = FNV_OFFSET);

inline uint64_t hash_variant(const godot::Variant &v, uint64_t hash)
{
	int type = static_cast<int>(v.get_type());
	hash = hash_combine(hash, static_cast<uint64_t>(type));

	switch (v.get_type())
	{
		case godot::Variant::NIL:
			break;
		case godot::Variant::BOOL:
		{
			bool b = v;
			hash = hash_combine(hash, b ? 1ULL : 0ULL);
			break;
		}
		case godot::Variant::INT:
		{
			int64_t i = v;
			hash = fnv1a(&i, sizeof(i), hash);
			break;
		}
		case godot::Variant::FLOAT:
		{
			double d = v;
			hash = fnv1a(&d, sizeof(d), hash);
			break;
		}
		case godot::Variant::STRING:
		{
			godot::String s = v;
			hash = hash_string(s, hash);
			break;
		}
		case godot::Variant::VECTOR3:
		{
			godot::Vector3 vec = v;
			hash = fnv1a(&vec.x, sizeof(float) * 3, hash);
			break;
		}
		case godot::Variant::DICTIONARY:
		{
			godot::Dictionary d = v;
			hash = hash_dictionary(d, hash);
			break;
		}
		case godot::Variant::ARRAY:
		{
			godot::Array a = v;
			hash = hash_array(a, hash);
			break;
		}
		case godot::Variant::PACKED_BYTE_ARRAY:
		{
			godot::PackedByteArray a = v;
			hash = hash_packed_byte(a, hash);
			break;
		}
		case godot::Variant::PACKED_INT32_ARRAY:
		{
			godot::PackedInt32Array a = v;
			hash = hash_packed_int32(a, hash);
			break;
		}
		case godot::Variant::PACKED_VECTOR3_ARRAY:
		{
			godot::PackedVector3Array a = v;
			hash = hash_packed_vector3(a, hash);
			break;
		}
		case godot::Variant::PACKED_COLOR_ARRAY:
		{
			godot::PackedColorArray a = v;
			hash = hash_packed_color(a, hash);
			break;
		}
		default:
			// For unsupported types, hash the type tag only (will cause cache misses but not incorrect caching)
			break;
	}
	return hash;
}

inline uint64_t hash_dictionary(const godot::Dictionary &d, uint64_t hash)
{
	int size = d.size();
	hash = hash_combine(hash, static_cast<uint64_t>(size));
	godot::Array keys = d.keys();
	for (int i = 0; i < keys.size(); ++i)
	{
		hash = hash_variant(keys[i], hash);
		hash = hash_variant(d[keys[i]], hash);
	}
	return hash;
}

inline uint64_t hash_array(const godot::Array &arr, uint64_t hash)
{
	int size = arr.size();
	hash = hash_combine(hash, static_cast<uint64_t>(size));
	for (int i = 0; i < size; ++i)
	{
		hash = hash_variant(arr[i], hash);
	}
	return hash;
}

} // namespace HEGo::Util::Hash

#endif // HEGO_UTIL_HASH_FNV_H
