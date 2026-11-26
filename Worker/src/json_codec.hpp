#ifndef LITEDICTATE_JSON_CODEC_HPP
#define LITEDICTATE_JSON_CODEC_HPP

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace litedictate {

// Minimal, zero-dependency RFC 8259 JSON DOM + serializer for LDP1 payloads.
struct JsonValue {
    enum class Type { Null, Bool, Int, Double, String, Array, Object };

    Type type = Type::Null;
    bool bool_val = false;
    int64_t int_val = 0;
    double double_val = 0.0;
    std::string str_val;
    std::vector<JsonValue> arr_val;
    std::map<std::string, JsonValue> obj_val;

    bool isNull() const { return type == Type::Null; }
    bool isBool() const { return type == Type::Bool; }
    bool isNumber() const { return type == Type::Int || type == Type::Double; }
    bool isString() const { return type == Type::String; }
    bool isArray() const { return type == Type::Array; }
    bool isObject() const { return type == Type::Object; }

    int64_t asInt(int64_t fallback = 0) const {
        if (type == Type::Int) return int_val;
        if (type == Type::Double && std::isfinite(double_val)) return static_cast<int64_t>(double_val);
        return fallback;
    }

    double asDouble(double fallback = 0.0) const {
        if (type == Type::Double) return double_val;
        if (type == Type::Int) return static_cast<double>(int_val);
        return fallback;
    }

    const JsonValue *find(const std::string &key) const {
        if (type != Type::Object) return nullptr;
        auto it = obj_val.find(key);
        return it == obj_val.end() ? nullptr : &it->second;
    }
};

class JsonParser {
public:
    static bool parse(const char *data, size_t len, JsonValue &out, std::string &err) {
        JsonParser p(data, len);
        p.skipWs();
        if (!p.parseValue(out, 0)) {
            err = p.err_.empty() ? "Invalid JSON" : p.err_;
            return false;
        }
        p.skipWs();
        if (p.pos_ != p.len_) {
            err = "Trailing characters after JSON value";
            return false;
        }
        return true;
    }

private:
    static constexpr int kMaxDepth = 32;
    const char *data_;
    size_t len_;
    size_t pos_ = 0;
    std::string err_;

    JsonParser(const char *data, size_t len) : data_(data), len_(len) {}

    void skipWs() {
        while (pos_ < len_) {
            char c = data_[pos_];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                ++pos_;
            } else {
                break;
            }
        }
    }

    bool parseValue(JsonValue &out, int depth) {
        if (depth > kMaxDepth) {
            err_ = "JSON nesting depth exceeded";
            return false;
        }
        skipWs();
        if (pos_ >= len_) {
            err_ = "Unexpected end of JSON";
            return false;
        }
        char c = data_[pos_];
        if (c == '{') return parseObject(out, depth + 1);
        if (c == '[') return parseArray(out, depth + 1);
        if (c == '"') {
            out = JsonValue{};
            out.type = JsonValue::Type::String;
            return parseString(out.str_val);
        }
        if (c == 't') return parseLiteral("true", JsonValue::Type::Bool, true, out);
        if (c == 'f') return parseLiteral("false", JsonValue::Type::Bool, false, out);
        if (c == 'n') return parseLiteral("null", JsonValue::Type::Null, false, out);
        if (c == '-' || (c >= '0' && c <= '9')) return parseNumber(out);
        err_ = "Unexpected token in JSON";
        return false;
    }

    bool parseLiteral(const char *lit, JsonValue::Type t, bool bval, JsonValue &out) {
        size_t n = std::strlen(lit);
        if (pos_ + n > len_ || std::memcmp(data_ + pos_, lit, n) != 0) {
            err_ = "Invalid JSON literal";
            return false;
        }
        pos_ += n;
        out = JsonValue{};
        out.type = t;
        out.bool_val = bval;
        return true;
    }

    static bool hexDigit(char c, uint32_t &v) {
        if (c >= '0' && c <= '9') { v = static_cast<uint32_t>(c - '0'); return true; }
        if (c >= 'a' && c <= 'f') { v = static_cast<uint32_t>(10 + (c - 'a')); return true; }
        if (c >= 'A' && c <= 'F') { v = static_cast<uint32_t>(10 + (c - 'A')); return true; }
        return false;
    }

    bool parseHex4(uint32_t &cp) {
        if (pos_ + 4 > len_) {
            err_ = "Truncated unicode escape";
            return false;
        }
        cp = 0;
        for (int i = 0; i < 4; ++i) {
            uint32_t d = 0;
            if (!hexDigit(data_[pos_++], d)) {
                err_ = "Invalid hex digit in unicode escape";
                return false;
            }
            cp = (cp << 4) | d;
        }
        return true;
    }

    static void appendUtf8(std::string &out, uint32_t cp) {
        if (cp <= 0x7Fu) {
            out.push_back(static_cast<char>(cp));
        } else if (cp <= 0x7FFu) {
            out.push_back(static_cast<char>(0xC0u | ((cp >> 6) & 0x1Fu)));
            out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
        } else if (cp <= 0xFFFFu) {
            out.push_back(static_cast<char>(0xE0u | ((cp >> 12) & 0x0Fu)));
            out.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
            out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
        } else if (cp <= 0x10FFFFu) {
            out.push_back(static_cast<char>(0xF0u | ((cp >> 18) & 0x07u)));
            out.push_back(static_cast<char>(0x80u | ((cp >> 12) & 0x3Fu)));
            out.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
            out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
        }
    }

    bool parseString(std::string &out) {
        if (pos_ >= len_ || data_[pos_] != '"') {
            err_ = "Expected '\"'";
            return false;
        }
        ++pos_;
        out.clear();
        while (pos_ < len_) {
            unsigned char c = static_cast<unsigned char>(data_[pos_++]);
            if (c == '"') return true;
            if (c < 0x20u) {
                err_ = "Unescaped control char in JSON string";
                return false;
            }
            if (c == '\\') {
                if (pos_ >= len_) {
                    err_ = "Truncated escape sequence";
                    return false;
                }
                char esc = data_[pos_++];
                switch (esc) {
                    case '"':  out.push_back('"');  break;
                    case '\\': out.push_back('\\'); break;
                    case '/':  out.push_back('/');  break;
                    case 'b':  out.push_back('\b'); break;
                    case 'f':  out.push_back('\f'); break;
                    case 'n':  out.push_back('\n'); break;
                    case 'r':  out.push_back('\r'); break;
                    case 't':  out.push_back('\t'); break;
                    case 'u': {
                        uint32_t cp = 0;
                        if (!parseHex4(cp)) return false;
                        if (cp >= 0xD800u && cp <= 0xDBFFu) {
                            if (pos_ + 2 <= len_ && data_[pos_] == '\\' && data_[pos_ + 1] == 'u') {
                                pos_ += 2;
                                uint32_t low = 0;
                                if (!parseHex4(low)) return false;
                                if (low < 0xDC00u || low > 0xDFFFu) {
                                    err_ = "Invalid UTF-16 low surrogate";
                                    return false;
                                }
                                cp = 0x10000u + (((cp - 0xD800u) << 10) | (low - 0xDC00u));
                            } else {
                                err_ = "Unpaired UTF-16 high surrogate";
                                return false;
                            }
                        } else if (cp >= 0xDC00u && cp <= 0xDFFFu) {
                            err_ = "Unexpected UTF-16 low surrogate";
                            return false;
                        }
                        appendUtf8(out, cp);
                        break;
                    }
                    default:
                        err_ = "Invalid escape character";
                        return false;
                }
            } else {
                out.push_back(static_cast<char>(c));
            }
        }
        err_ = "Unterminated JSON string";
        return false;
    }

    bool parseNumber(JsonValue &out) {
        size_t start = pos_;
        bool is_float = false;
        if (pos_ < len_ && data_[pos_] == '-') ++pos_;
        if (pos_ >= len_) { err_ = "Invalid number"; return false; }
        if (data_[pos_] == '0') {
            ++pos_;
        } else if (data_[pos_] >= '1' && data_[pos_] <= '9') {
            while (pos_ < len_ && data_[pos_] >= '0' && data_[pos_] <= '9') ++pos_;
        } else {
            err_ = "Invalid number";
            return false;
        }
        if (pos_ < len_ && data_[pos_] == '.') {
            is_float = true;
            ++pos_;
            if (pos_ >= len_ || data_[pos_] < '0' || data_[pos_] > '9') {
                err_ = "Invalid fractional number";
                return false;
            }
            while (pos_ < len_ && data_[pos_] >= '0' && data_[pos_] <= '9') ++pos_;
        }
        if (pos_ < len_ && (data_[pos_] == 'e' || data_[pos_] == 'E')) {
            is_float = true;
            ++pos_;
            if (pos_ < len_ && (data_[pos_] == '+' || data_[pos_] == '-')) ++pos_;
            if (pos_ >= len_ || data_[pos_] < '0' || data_[pos_] > '9') {
                err_ = "Invalid exponent";
                return false;
            }
            while (pos_ < len_ && data_[pos_] >= '0' && data_[pos_] <= '9') ++pos_;
        }
        std::string num_str(data_ + start, pos_ - start);
        out = JsonValue{};
        if (!is_float) {
            char *endp = nullptr;
            errno = 0;
            long long v = std::strtoll(num_str.c_str(), &endp, 10);
            if (errno == 0 && endp && *endp == '\0') {
                out.type = JsonValue::Type::Int;
                out.int_val = static_cast<int64_t>(v);
                return true;
            }
        }
        char *endp = nullptr;
        errno = 0;
        double d = std::strtod(num_str.c_str(), &endp);
        if (errno != 0 || !endp || *endp != '\0' || !std::isfinite(d)) {
            err_ = "Number out of range";
            return false;
        }
        out.type = JsonValue::Type::Double;
        out.double_val = d;
        return true;
    }

    bool parseArray(JsonValue &out, int depth) {
        ++pos_; // '['
        out = JsonValue{};
        out.type = JsonValue::Type::Array;
        skipWs();
        if (pos_ < len_ && data_[pos_] == ']') {
            ++pos_;
            return true;
        }
        while (true) {
            JsonValue elem;
            if (!parseValue(elem, depth)) return false;
            out.arr_val.push_back(std::move(elem));
            skipWs();
            if (pos_ >= len_) { err_ = "Unterminated array"; return false; }
            if (data_[pos_] == ']') { ++pos_; return true; }
            if (data_[pos_] != ',') { err_ = "Expected ',' or ']' in array"; return false; }
            ++pos_;
        }
    }

    bool parseObject(JsonValue &out, int depth) {
        ++pos_; // '{'
        out = JsonValue{};
        out.type = JsonValue::Type::Object;
        skipWs();
        if (pos_ < len_ && data_[pos_] == '}') {
            ++pos_;
            return true;
        }
        while (true) {
            skipWs();
            std::string key;
            if (!parseString(key)) return false;
            skipWs();
            if (pos_ >= len_ || data_[pos_] != ':') {
                err_ = "Expected ':' in object";
                return false;
            }
            ++pos_;
            JsonValue val;
            if (!parseValue(val, depth)) return false;
            out.obj_val[std::move(key)] = std::move(val);
            skipWs();
            if (pos_ >= len_) { err_ = "Unterminated object"; return false; }
            if (data_[pos_] == '}') { ++pos_; return true; }
            if (data_[pos_] != ',') { err_ = "Expected ',' or '}' in object"; return false; }
            ++pos_;
        }
    }
};

class JsonBuilder {
public:
    JsonBuilder() { buf_.reserve(256); buf_.push_back('{'); }

    void addString(const char *key, const std::string &val) {
        addKey(key);
        appendEscaped(val);
    }

    void addBool(const char *key, bool val) {
        addKey(key);
        buf_.append(val ? "true" : "false");
    }

    void addInt64(const char *key, int64_t val) {
        addKey(key);
        buf_.append(std::to_string(val));
    }

    void addUint64(const char *key, uint64_t val) {
        addKey(key);
        buf_.append(std::to_string(val));
    }

    void addDouble(const char *key, double val) {
        addKey(key);
        if (!std::isfinite(val)) {
            buf_.append("0");
            return;
        }
        char tmp[64];
        std::snprintf(tmp, sizeof(tmp), "%.3f", val);
        buf_.append(tmp);
    }

    void addStringArray(const char *key, const std::vector<std::string> &vals) {
        addKey(key);
        buf_.push_back('[');
        for (size_t i = 0; i < vals.size(); ++i) {
            if (i > 0) buf_.push_back(',');
            appendEscaped(vals[i]);
        }
        buf_.push_back(']');
    }

    std::string finish() {
        buf_.push_back('}');
        return std::move(buf_);
    }

private:
    std::string buf_;
    bool has_field_ = false;

    void addKey(const char *key) {
        if (has_field_) buf_.push_back(',');
        has_field_ = true;
        appendEscaped(key);
        buf_.push_back(':');
    }

    void appendEscaped(const std::string &s) {
        buf_.push_back('"');
        for (unsigned char c : s) {
            switch (c) {
                case '"':  buf_.append("\\\""); break;
                case '\\': buf_.append("\\\\"); break;
                case '\b': buf_.append("\\b");  break;
                case '\f': buf_.append("\\f");  break;
                case '\n': buf_.append("\\n");  break;
                case '\r': buf_.append("\\r");  break;
                case '\t': buf_.append("\\t");  break;
                default:
                    if (c < 0x20u) {
                        char u[8];
                        std::snprintf(u, sizeof(u), "\\u%04x", static_cast<unsigned int>(c));
                        buf_.append(u);
                    } else {
                        buf_.push_back(static_cast<char>(c));
                    }
                    break;
            }
        }
        buf_.push_back('"');
    }
};

} // namespace litedictate

#endif // LITEDICTATE_JSON_CODEC_HPP
