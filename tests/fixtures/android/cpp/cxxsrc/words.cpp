#include <stdexcept>
#include <string>
#include <vector>

// The C++ runtime at work: std::string and std::vector allocate through
// libc++, and the exception unwinds through libc++abi.
static std::vector<std::string> split(const std::string &s) {
    std::vector<std::string> out;
    std::string word;
    for (char c : s) {
        if (c == ' ') {
            if (word.empty()) throw std::invalid_argument("empty word");
            out.push_back(word);
            word.clear();
        } else {
            word += c;
        }
    }
    if (!word.empty()) out.push_back(word);
    return out;
}

extern "C" int count_words(const char *s) {
    try {
        return static_cast<int>(split(s).size());
    } catch (const std::invalid_argument &) {
        return -1;
    }
}

// __FILE__ through the unit's -ffile-prefix-map: no store path.
extern "C" const char *cxx_source_file(void) { return __FILE__; }
