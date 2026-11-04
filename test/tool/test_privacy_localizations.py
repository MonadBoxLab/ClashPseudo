"""固定隐私定稿的逐字内容与分节接口，不依赖 Flutter 或业务模块。"""

import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SECTIONS = (
    "privacyDataProcessing",
    "privacyNetworkCommunication",
    "privacyPermissionPurposes",
    "privacyFilesAndBackups",
    "privacyRecordsAndLogs",
    "privacyDeletingData",
)
# 完整隐私说明的UTF-8摘要；全文与分节同时检查。
APPROVED_BODY_SHA256 = {
    "zh": "6021980a6239995b15846d607430074153db57e13bc08a71eb9ce2cf69bafe23",
    "en": "03cd5dbdd18129d96d164aedf3c3386d4aa8b92523bc5d2acdde2cdab10af45f",
}
APPROVED_SHORT = {
    "zh": {
        "privacyNoticeTitle": "隐私与许可",
        "privacyNoticeUnderstood": "我已了解",
        "privacyNoticeReadFull": "完整说明",
        "privacyNoticeIntro": "Clash Pseudo 开源、免费，不进行用户数据采集或上报，不提供任何代理节点或订阅服务。",
        "privacyNoticeLicenseNotice": "更多请参见 GPLv3 协议。",
        "privacyNoticeNotSaved": "未能确认提示记录已保存。下次打开可能再次显示。",
        "sourceDistributionNotice": "对应源码与构建材料随发行版本提供。",
    },
    "en": {
        "privacyNoticeTitle": "Privacy and license",
        "privacyNoticeUnderstood": "Understood",
        "privacyNoticeReadFull": "Full notice",
        "privacyNoticeIntro": "Clash Pseudo is free and open source. It does not collect or report user data and does not provide any proxy nodes or subscription services.",
        "privacyNoticeLicenseNotice": "See GPLv3 for more information.",
        "privacyNoticeNotSaved": "Could not confirm that the notice was recorded. It may appear again on next launch.",
        "sourceDistributionNotice": "Corresponding source and build materials are provided with each release.",
    },
}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate ARB key: " + key)
        result[key] = value
    return result


class PrivacyLocalizationsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.locales = {
            locale: json.loads(
                (ROOT / "lib/src/l10n" / ("app_" + locale + ".arb")).read_text(),
                object_pairs_hook=unique_object,
            )
            for locale in APPROVED_BODY_SHA256
        }

    def test_complete_notice_is_verbatim_approved_text(self):
        for locale, digest in APPROVED_BODY_SHA256.items():
            with self.subTest(locale=locale):
                body = self.locales[locale]["privacyNoticeBody"]
                self.assertEqual(hashlib.sha256(body.encode()).hexdigest(), digest)

    def test_sections_reassemble_the_same_complete_notice(self):
        for locale, strings in self.locales.items():
            with self.subTest(locale=locale):
                sections = [strings["privacyNoticeIntro"]]
                for section in SECTIONS:
                    sections.extend((strings[section + "Title"], strings[section + "Body"]))
                sections.extend((
                    strings["privacyProjectRepositoryTitle"],
                    strings["projectRepositoryUrl"],
                    strings["privacyNoticeLicenseNotice"],
                ))
                self.assertEqual(strings["privacyNoticeBody"], "\n\n".join(sections))
                self.assertNotIn("**", strings["privacyNoticeBody"])
                self.assertEqual(strings["privacyPermissionPurposesBody"].count("\n- "), 3)
                self.assertTrue(strings["privacyPermissionPurposesBody"].startswith("- "))

    def test_short_notice_and_follow_up_labels_are_fixed(self):
        for locale, expected in APPROVED_SHORT.items():
            strings = self.locales[locale]
            for key, value in expected.items():
                with self.subTest(locale=locale, key=key):
                    self.assertEqual(strings[key], value)

    def test_repository_is_the_complete_copyable_url_and_gpl_label_is_stable(self):
        for locale, strings in self.locales.items():
            with self.subTest(locale=locale):
                self.assertEqual(strings["projectRepositoryUrl"], "https://github.com/MonadBoxLab/ClashPseudo")
                self.assertEqual(strings["privacyNoticeLicenseName"], "GPLv3")
                self.assertIn(strings["privacyNoticeLicenseName"], strings["privacyNoticeLicenseNotice"])

    def test_local_log_omissions_have_a_separate_integer_placeholder(self):
        expected = {
            "zh": "已略过 {count} 条日志",
            "en": "Omitted {count} log entries",
        }
        for locale, text in expected.items():
            with self.subTest(locale=locale):
                strings = self.locales[locale]
                self.assertEqual(strings["logLocalDropped"], text)
                self.assertEqual(
                    strings["@logLocalDropped"]["placeholders"],
                    {"count": {"type": "int"}},
                )
                self.assertNotEqual(strings["logLocalDropped"], strings["logDropped"])

    def test_both_locales_expose_the_same_message_keys(self):
        keys = [
            {key for key in strings if not key.startswith("@")}
            for strings in self.locales.values()
        ]
        self.assertEqual(keys[0], keys[1])

    def test_duplicate_keys_are_not_silently_accepted(self):
        with self.assertRaisesRegex(ValueError, "Duplicate ARB key"):
            json.loads('{"privacyNoticeBody":"first","privacyNoticeBody":"second"}',
                       object_pairs_hook=unique_object)


if __name__ == "__main__":
    unittest.main()
