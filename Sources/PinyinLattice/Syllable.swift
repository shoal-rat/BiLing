import Foundation

public enum PinyinMode: String, Codable, Sendable {
    case chinesePrimary
    case chineseWithEnglish
    case englishPrimary
    case literal
}

public struct SyllableInventory: Sendable {
    public let syllables: Set<String>
    public let prefixes: Set<String>

    public init(_ syllables: Set<String>) {
        self.syllables = syllables
        self.prefixes = Set(syllables.flatMap { syllable in
            (1...syllable.count).map { String(syllable.prefix($0)) }
        })
    }

    public static let standard: SyllableInventory = {
        let raw = """
        a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
        ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
        da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
        e ei en eng er
        fa fan fang fei fen feng fo fou fu
        ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
        ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
        ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
        ka kai kan kang kao ke ken keng kong kou ku kua kuai kuan kuang kui kun kuo
        la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve
        ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
        na nai nan nang nao ne nei nen neng ng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve
        o ou
        pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
        qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
        ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
        sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
        ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
        wa wai wan wang wei wen weng wo wu
        xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
        ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
        za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
        """
        return SyllableInventory(Set(raw.split(whereSeparator: \.isWhitespace).map(String.init)))
    }()
}

public enum PinyinNormalizer {
    public static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "ü", with: "v")
            .filter { $0.isLetter || $0 == "'" }
    }

    public static func lookupKey(_ raw: String) -> String {
        normalize(raw).replacingOccurrences(of: "'", with: "")
    }

    public static func mode(for raw: String, inventory: SyllableInventory = .standard) -> PinyinMode {
        guard !raw.isEmpty else { return .chinesePrimary }
        if raw.contains(where: \.isUppercase) || raw.contains("@") || raw.contains("://") {
            return .literal
        }
        let normalized = normalize(raw)
        let segmenter = Segmenter(inventory: inventory)
        let segmentation = segmenter.segment(normalized)
        if segmentation.isComplete {
            return .chinesePrimary
        }
        if normalized.split(separator: "'").allSatisfy({ inventory.prefixes.contains(String($0)) }) {
            return .chineseWithEnglish
        }
        // Mostly-pinyin buffers with a trailing remainder (beijinghy = 北京
        // + initials hy) are Chinese with a tail, not English: the lattice
        // consumed at least half of the letters.
        if segmentation.consumedCharacters > 0,
           segmentation.consumedCharacters * 2 >= segmentation.inputLength {
            return .chineseWithEnglish
        }
        return .englishPrimary
    }
}
