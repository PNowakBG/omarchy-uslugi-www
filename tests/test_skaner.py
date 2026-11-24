"""Testy skanera uslugi-www-stan (stdlib, bez zależności).

Uruchomienie z katalogu wtyczki:
    python3 -I -B -m unittest discover -s tests -v
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCIEZKA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "uslugi-www-stan")


def wczytaj_skaner():
    loader = importlib.machinery.SourceFileLoader("uslugi_www_stan", SCIEZKA)
    spec = importlib.util.spec_from_loader("uslugi_www_stan", loader)
    modul = importlib.util.module_from_spec(spec)
    loader.exec_module(modul)
    return modul


S = wczytaj_skaner()


class Cgroup(unittest.TestCase):
    def test_jednostka_uzytkownika(self):
        cg = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/gosek-panel.service\n"
        self.assertEqual(S.jednostka_z_cgroup(cg), ("user", "gosek-panel.service"))

    def test_jednostka_systemowa(self):
        self.assertEqual(S.jednostka_z_cgroup("0::/system.slice/minio.service"), ("system", "minio.service"))

    def test_scope_aplikacji(self):
        cg = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-herdr-a57d1bfb.scope"
        self.assertEqual(S.jednostka_z_cgroup(cg), ("user", "app-Hyprland-herdr-a57d1bfb.scope"))

    def test_brak_jednostki(self):
        self.assertEqual(S.jednostka_z_cgroup(""), ("", ""))

    def test_aplikacja_z_jednostki(self):
        self.assertEqual(S.aplikacja_z_jednostki("app-Hyprland-herdr-a57d1bfb.scope"), "herdr")
        self.assertEqual(S.aplikacja_z_jednostki("app-Hyprland-xdg\\x2dterminal\\x2dexec-cdba18a1.scope"), "terminal")
        self.assertEqual(S.aplikacja_z_jednostki("app-Hyprland-org.wezfurlong.wezterm@abc123.service"), "WezTerm")
        # nieznana aplikacja zostaje pod własną nazwą — rozpoznawanie jest uniwersalne
        self.assertEqual(S.aplikacja_z_jednostki("app-Hyprland-t3code-0123abcd.scope"), "T3 Code")
        self.assertEqual(S.aplikacja_z_jednostki("app-Hyprland-nowyterminal-0123abcd.scope"), "nowyterminal")
        self.assertEqual(S.aplikacja_z_jednostki("hc-hold-0c5b77d1.service"), "")


class Projekty(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home_stary = S.HOME
        S.HOME = self.tmp.name

    def tearDown(self):
        S.HOME = self.home_stary
        self.tmp.cleanup()

    def test_repozytorium(self):
        repo = os.path.join(self.tmp.name, "Projects", "Sklep")
        os.makedirs(os.path.join(repo, ".git"))
        os.makedirs(os.path.join(repo, "web"))
        info = S.projekt_info(os.path.join(repo, "web"))
        self.assertEqual(info, {"projekt": "Sklep", "worktree": False, "istnieje": True,
                                "korzen": "~/Projects/Sklep"})

    def test_worktree_gita(self):
        wt = os.path.join(self.tmp.name, "Projects", "CRM-wt", "feature-3")
        os.makedirs(wt)
        with open(os.path.join(wt, ".git"), "w") as f:
            f.write("gitdir: /home/x/Projects/CRM/.git/worktrees/feature-3\n")
        info = S.projekt_info(wt)
        self.assertEqual(info, {"projekt": "CRM / feature-3", "worktree": True, "istnieje": True,
                                "korzen": "~/Projects/CRM-wt/feature-3"})

    def test_usuniety_worktree(self):
        # docker compose: katalog roboczy z etykiety, którego już nie ma
        sciezka = os.path.join(self.tmp.name, "Projects", "CRM-wt", "feature-login", "docker")
        info = S.projekt_info(sciezka)
        self.assertEqual((info["projekt"], info["worktree"], info["istnieje"]),
                         ("CRM / feature-login", True, False))

    def _usun_i_porownaj(self, korzen_wt, podfolder, gitdir):
        os.makedirs(os.path.join(korzen_wt, podfolder))
        with open(os.path.join(korzen_wt, ".git"), "w") as f:
            f.write(f"gitdir: {gitdir}\n")
        cwd = os.path.join(korzen_wt, podfolder)
        przed = S.projekt_info(cwd)
        shutil.rmtree(korzen_wt)
        # tak jądro pokazuje cwd procesu, którego folder usunięto
        po = S.projekt_info(cwd + " (deleted)")
        self.assertTrue(przed["istnieje"])
        self.assertFalse(po["istnieje"])
        self.assertEqual(przed["korzen"], po["korzen"])
        self.assertEqual(przed["projekt"], po["projekt"])
        return przed

    def test_klucz_stabilny_po_usunieciu_worktree_wt(self):
        wt = os.path.join(self.tmp.name, "Projects", "CRM-wt", "feature-9")
        info = self._usun_i_porownaj(wt, "web", "/x/Projects/CRM/.git/worktrees/feature-9")
        self.assertEqual(info["projekt"], "CRM / feature-9")

    def test_klucz_stabilny_po_usunieciu_worktree_claude(self):
        repo = os.path.join(self.tmp.name, "Projects", "CRM")
        os.makedirs(os.path.join(repo, ".git"))
        wt = os.path.join(repo, ".claude", "worktrees", "feat-x")
        info = self._usun_i_porownaj(wt, "web", repo + "/.git/worktrees/feat-x")
        self.assertEqual(info["projekt"], "CRM / feat-x")
        # nie zlewa się z głównym checkoutem
        self.assertNotEqual(info["korzen"], S.projekt_info(repo)["korzen"])

    def test_klucz_stabilny_po_usunieciu_worktree_codex(self):
        wt = os.path.join(self.tmp.name, ".codex", "worktrees", "a1b2", "CRM")
        info = self._usun_i_porownaj(wt, "src", "/x/Projects/CRM/.git/worktrees/CRM")
        self.assertEqual(info["projekt"], "CRM / a1b2")

    def test_usuniety_checkout_tymczasowy_zostaje_pod_stalym_folderem(self):
        repo = os.path.join(self.tmp.name, ".config", "herdr-web-ui", "updates", "a069ea6b444c846b", "release-yPWOGk")
        os.makedirs(os.path.join(repo, ".git"))
        przed = S.projekt_info(repo)
        shutil.rmtree(os.path.join(self.tmp.name, ".config", "herdr-web-ui", "updates"))
        po = S.projekt_info(repo + " (deleted)")
        self.assertEqual(przed["korzen"], po["korzen"])
        self.assertEqual(po["korzen"], "~/.config/herdr-web-ui")

    def _podfolder_znika(self, repo, podfolder):
        """Serwer z podfolderu (np. dist/), który przebudowa usuwa i tworzy na nowo."""
        os.makedirs(os.path.join(repo, ".git"))
        cwd = os.path.join(repo, podfolder)
        os.makedirs(cwd)
        przed = S.projekt_info(cwd)
        shutil.rmtree(cwd)
        os.makedirs(cwd)   # nowy folder o tej samej nazwie — proces trzyma stary (deleted)
        po = S.projekt_info(cwd + " (deleted)")
        self.assertFalse(po["istnieje"])
        self.assertEqual((przed["korzen"], przed["projekt"]), (po["korzen"], po["projekt"]))
        return po

    def test_usuniety_podfolder_w_projekcie(self):
        po = self._podfolder_znika(os.path.join(self.tmp.name, "Projects", "Sklep"), "dist")
        self.assertEqual(po["korzen"], "~/Projects/Sklep")

    def test_usuniety_podfolder_poza_projects(self):
        po = self._podfolder_znika(os.path.join(self.tmp.name, "code", "app"), "build")
        self.assertEqual(po["korzen"], "~/code/app")

    def test_usuniety_podfolder_bez_gita(self):
        cwd = os.path.join(self.tmp.name, "www", "strona", "dist")
        os.makedirs(cwd)
        przed = S.projekt_info(cwd)
        shutil.rmtree(cwd)
        self.assertEqual(przed["korzen"], S.projekt_info(cwd + " (deleted)")["korzen"])

    def test_caly_repo_poza_projects_usuniety(self):
        # Z samej ścieżki nie da się już ustalić, że usunięty folder był repo —
        # klucz trzyma pamięć procesu z poprzedniego skanu (skaner chodzi co 15 s).
        repo = os.path.join(self.tmp.name, ".config", "omarchy", "plugins", "moja.wtyczka")
        os.makedirs(os.path.join(repo, ".git"))
        S._PAMIEC_PROJEKTOW, S._NOWA_PAMIEC = {}, {}
        przed = S.pamiec_projektu(os.getpid(), S.projekt_info(repo))
        S._PAMIEC_PROJEKTOW, S._NOWA_PAMIEC = S._NOWA_PAMIEC, {}
        shutil.rmtree(repo)
        po = S.pamiec_projektu(os.getpid(), S.projekt_info(repo + " (deleted)"))
        S._PAMIEC_PROJEKTOW, S._NOWA_PAMIEC = {}, {}
        self.assertEqual((przed["korzen"], przed["projekt"]), (po["korzen"], po["projekt"]))
        self.assertEqual(po["korzen"], "~/.config/omarchy/plugins/moja.wtyczka")
        self.assertFalse(po["istnieje"])

    def test_worktree_t3_etykieta_przed_i_po(self):
        wt = os.path.join(self.tmp.name, ".t3", "worktrees", "CRM", "feature-login")
        info = self._usun_i_porownaj(wt, "web", "/x/Projects/CRM/.git/worktrees/feature-login")
        self.assertEqual(info["projekt"], "CRM / feature-login")

    def test_pamiec_procesu_po_usunieciu(self):
        # skaner widział proces przy żywym folderze → po usunięciu bierze zapamiętany korzeń
        S._PAMIEC_PROJEKTOW, S._NOWA_PAMIEC = {}, {}
        zywy = {"projekt": "moja-apka", "worktree": False, "istnieje": True, "korzen": "~/x/moja-apka"}
        S.pamiec_projektu(os.getpid(), zywy)
        S._PAMIEC_PROJEKTOW, S._NOWA_PAMIEC = S._NOWA_PAMIEC, {}
        martwy = {"projekt": "~/x", "worktree": False, "istnieje": False, "korzen": "~/x/moja-apka/out"}
        wynik = S.pamiec_projektu(os.getpid(), martwy)
        self.assertEqual((wynik["korzen"], wynik["projekt"], wynik["istnieje"]),
                         ("~/x/moja-apka", "moja-apka", False))
        S._PAMIEC_PROJEKTOW, S._NOWA_PAMIEC = {}, {}

    def test_dotfiles_w_home_nie_sa_projektem(self):
        os.makedirs(os.path.join(self.tmp.name, ".git"))
        os.makedirs(os.path.join(self.tmp.name, "notatki"))
        info = S.projekt_info(os.path.join(self.tmp.name, "notatki"))
        self.assertEqual(info["projekt"], "~/notatki")
        self.assertFalse(info["worktree"])

    def test_checkout_w_katalogu_tymczasowym(self):
        # herdr rozpakowuje aktualizację do ~/.config/herdr-web-ui/updates/<hash>/release-XXXXXX
        repo = os.path.join(self.tmp.name, ".config", "herdr-web-ui", "updates", "a069ea6b", "release-yPWOGk")
        os.makedirs(os.path.join(repo, ".git"))
        self.assertEqual(S.projekt_info(repo)["projekt"], "~/.config/herdr-web-ui")

    def test_losowe_nazwy(self):
        for nazwa in ("release-yPWOGk", "build_aB3xYz", "tmpk2j_9xq1"):
            self.assertTrue(S.LOSOWA_NAZWA.search(nazwa), nazwa)
        for nazwa in ("feature-login", "pablo.uslugi", "omarchy-uslugi-www", "app-v2beta1", "CRM", "Sklep-Web"):
            self.assertFalse(S.LOSOWA_NAZWA.search(nazwa), nazwa)

    def test_home_i_root(self):
        self.assertEqual(S.projekt_info(self.tmp.name)["projekt"], "")
        self.assertEqual(S.projekt_info("/")["projekt"], "")


class Historia(unittest.TestCase):
    def test_pierwszy_raz_bierze_najwczesniejszy_slad(self):
        h = {}
        od, start, restarty, zm = S.aktualizuj_historie(h, "k", 2000, 1000, 3000)
        self.assertEqual((od, start, restarty, zm), (1000, 2000, 0, True))

    def test_ten_sam_start_to_nie_restart(self):
        h = {}
        S.aktualizuj_historie(h, "k", 2000, None, 3000)
        od, start, restarty, _ = S.aktualizuj_historie(h, "k", 2003, None, 3015)
        self.assertEqual((od, start, restarty), (2000, 2000, 0))

    def test_nowy_start_to_restart(self):
        h = {}
        S.aktualizuj_historie(h, "k", 2000, None, 3000)
        od, start, restarty, zm = S.aktualizuj_historie(h, "k", 5000, None, 5010)
        self.assertEqual((od, start, restarty, zm), (2000, 5000, 1, True))
        _, _, restarty, _ = S.aktualizuj_historie(h, "k", 9000, None, 9010)
        self.assertEqual(restarty, 2)

    def test_wczesniejszy_slad_cofa_od(self):
        h = {}
        S.aktualizuj_historie(h, "k", 2000, None, 3000)
        od, _, _, zm = S.aktualizuj_historie(h, "k", 2000, 500, 3015)
        self.assertEqual((od, zm), (500, True))


class HistoriaICacheOdporne(unittest.TestCase):
    def test_zle_typy_w_historii_odrzucone(self):
        hist = {
            "dobry": {"od": 1, "start": 2, "restarty": 0, "widziana": 3},
            "zla-widziana": {"od": 1, "start": 2, "widziana": "abc"},
            "zly-start": {"od": 1, "start": "x", "widziana": 3},
            "nie-slownik": [1, 2],
            "bool": {"od": True, "start": 2, "widziana": 3},
        }
        self.assertEqual(list(S.czysc_historie(hist)), ["dobry"])

    def test_cache_cpu(self):
        stan = {"1": [10, 100.0], "2": ["x", 1], "3": [1], "4": "ab", "5": [5, 50.0]}
        self.assertEqual(S.czysc_cache(stan), {"1": [10, 100.0], "5": [5, 50.0]})

    def test_cache_cpu_przycinany(self):
        tmp = tempfile.TemporaryDirectory()
        stary = S.CACHE
        S.CACHE = os.path.join(tmp.name, "c.json")
        try:
            pamiec = {"1:5": {"projekt": "Sklep", "worktree": False, "korzen": "~/Projects/Sklep"},
                      "2:6": {"projekt": 1}}
            S.zapisz_cache_cpu({"1": [10, 1000.0], "2": [10, 600.0]}, 1000.0, pamiec)
            self.assertEqual(S.czytaj_json(S.CACHE, {}),
                             {"v": 2, "cpu": {"1": [10, 1000.0]},
                              "projekty": {"1:5": {"projekt": "Sklep", "worktree": False,
                                                   "korzen": "~/Projects/Sklep"}}})
        finally:
            S.CACHE = stary
            tmp.cleanup()

    def test_nan_i_nieskonczonosc_odrzucone(self):
        hist = json.loads('{"a": {"od": NaN, "start": 2, "widziana": 3},'
                          ' "b": {"od": 1, "start": 2, "widziana": 3, "restarty": Infinity},'
                          ' "c": {"od": 1, "start": 2, "widziana": 3}}')
        self.assertEqual(list(S.czysc_historie(hist)), ["c"])
        self.assertEqual(S.czysc_cache({"1": [float("nan"), 1.0], "2": [1, 2.0]}), {"2": [1, 2.0]})


class Gniazda(unittest.TestCase):
    def test_prefork_bierze_najstarszy_proces(self):
        tekst = ('LISTEN 0 2048 127.0.0.1:8000 0.0.0.0:* users:(("gunicorn",pid=900,fd=5),'
                 '("gunicorn",pid=500,fd=5),("gunicorn",pid=700,fd=5))\n'
                 'LISTEN 0 128 0.0.0.0:9000 0.0.0.0:*\n')
        wiek = {900: 30, 500: 10, 700: 20}.get
        self.assertEqual(S.parsuj_ss(tekst, wiek),
                         [("127.0.0.1", 8000, "gunicorn", 500, [500, 700, 900]),
                          ("0.0.0.0", 9000, None, None, [])])


class SladyAgentow(unittest.TestCase):
    AGENCI = dict(S.AGENCI)

    def env(self, *nazwy, ai=""):
        return {"nazwy": set(nazwy), "term_program": "", "ai_agent": ai, "deploy_docker": False}

    def test_znane_znaczniki(self):
        self.assertEqual(S.agent_ze_srodowiska(self.env("CLAUDECODE"), self.AGENCI, set())[0], "Claude Code")
        self.assertEqual(S.agent_ze_srodowiska(self.env("OPENCODE"), self.AGENCI, set())[0], "OpenCode")

    def test_konwencja_session_id(self):
        for z, oczekiwany in (("GOOSE_SESSION_ID", "Goose"), ("KIMI_CODE_SESSION_ID", "Kimi Code"),
                              ("CURSOR_AGENT_THREAD_ID", "Cursor Agent"), ("KIRO_CLI_SESSION_ID", "Kiro")):
            self.assertEqual(S.agent_ze_srodowiska(self.env(z), self.AGENCI, set())[0], oczekiwany, z)

    def test_obce_zmienne_nie_sa_agentem(self):
        e = self.env("XDG_SESSION_ID", "DBUS_SESSION_BUS_ADDRESS", "PI_HOME", "TERM", "CLAUDE_CODE_TMPDIR")
        self.assertEqual(S.agent_ze_srodowiska(e, self.AGENCI, set()), ("", ""))

    def test_zmienne_calej_sesji_pomijane(self):
        self.assertEqual(S.agent_ze_srodowiska(self.env("CLAUDECODE"), self.AGENCI, {"CLAUDECODE"}), ("", ""))

    def test_ai_agent(self):
        e = self.env("AI_AGENT", ai="claude-code_2-1-331_agent")
        self.assertEqual(S.agent_ze_srodowiska(e, self.AGENCI, set())[0], "Claude Code")
        e = self.env("AI_AGENT", ai="opencode")
        self.assertEqual(S.agent_ze_srodowiska(e, self.AGENCI, set())[0], "OpenCode")
        e = self.env("AI_AGENT", ai="nowyagent_1.2")
        self.assertEqual(S.agent_ze_srodowiska(e, self.AGENCI, set())[0], "nowyagent")


class Rozstrzyganie(unittest.TestCase):
    BAZA = {"sam": "", "agent_lancuch": "", "agent_env": "", "powloka": False, "gospodarz": "",
            "gospodarz_z_lancucha": False, "terminal_env": False, "jednostka": "",
            "jednostka_wlasna": False, "jednostka_stala": False, "jednostka_run": False,
            "menedzer": "", "worktree": False, "projekt": "", "istnieje": True}

    def r(self, **fakty):
        return S.rozstrzygnij(dict(self.BAZA, **fakty))

    def test_usluga_systemd(self):
        rodzaj, powody, _, wstaje = self.r(jednostka="x.service", jednostka_wlasna=True, jednostka_stala=True)
        self.assertEqual((rodzaj, wstaje), ("stala", True))

    def test_powloka_w_jednostce_pojemniku_nie_jest_stala(self):
        # serwer wpisany w tmux.service / sesji Hyprland: jednostka nie jest „jego”
        rodzaj, powody, _, wstaje = self.r(jednostka="tmux.service", jednostka_stala=True,
                                           powloka=True, gospodarz="tmux", gospodarz_z_lancucha=True)
        self.assertEqual((rodzaj, wstaje, powody), ("reczna", False, [["terminal", "tmux"]]))

    def test_odlaczony_z_terminala_jest_reczny(self):
        rodzaj, powody, _, _ = self.r(gospodarz="herdr", terminal_env=True)
        self.assertEqual((rodzaj, powody), ("reczna", [["odlaczona", "herdr"]]))

    def test_odlaczony_bez_terminala_jest_narzedziem(self):
        self.assertEqual(self.r(gospodarz="herdr")[0], "narzedzie")

    def test_program_bezposrednio_pod_gospodarzem(self):
        self.assertEqual(self.r(gospodarz="herdr", gospodarz_z_lancucha=True, terminal_env=True)[0], "narzedzie")

    def test_agent_wygrywa_z_jednostka_i_menedzerem(self):
        rodzaj, _, agent, wstaje = self.r(agent_lancuch="Claude Code", menedzer="pm2")
        self.assertEqual((rodzaj, agent, wstaje), ("test", "Claude Code", False))

    def test_worktree_bez_agenta(self):
        rodzaj, powody, _, _ = self.r(worktree=True, projekt="CRM / x", istnieje=False, powloka=True)
        self.assertEqual(rodzaj, "test")
        self.assertIn(["osierocona", ""], powody)


class Pojemniki(unittest.TestCase):
    def _proces_o_nazwie(self, nazwa):
        katalog = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, katalog)
        plik = os.path.join(katalog, nazwa)
        shutil.copy("/usr/bin/sleep", plik)
        p = subprocess.Popen([plik, "30"])
        self.addCleanup(lambda: (p.kill(), p.wait()))
        for _ in range(50):
            if S.comm(p.pid) == nazwa:
                break
            time.sleep(0.02)
        return p.pid

    def test_jednostka_tmux_to_pojemnik(self):
        self.assertTrue(S.jednostka_pojemnik("tmux.service", {"MainPID": str(self._proces_o_nazwie("tmux"))}))

    def test_zwykla_usluga_to_nie_pojemnik(self):
        self.assertFalse(S.jednostka_pojemnik("app.service", {"MainPID": str(self._proces_o_nazwie("uvicorn"))}))

    def test_kontener_podman_to_nie_pojemnik(self):
        # Quadlet: głównym procesem jednostki jest conmon — to prawdziwa usługa
        self.assertFalse(S.jednostka_pojemnik("baza.service", {"MainPID": str(self._proces_o_nazwie("conmon"))}))

    def test_sesja_hyprland_to_pojemnik(self):
        self.assertTrue(S.jednostka_pojemnik("wayland-wm@hyprland.desktop.service", {"MainPID": "0"}))


class UstawieniaWlasne(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.plik_stary = S.USTAWIENIA_PLIK
        S.USTAWIENIA_PLIK = os.path.join(self.tmp.name, "uslugi.json")

    def tearDown(self):
        S.USTAWIENIA_PLIK = self.plik_stary
        self.tmp.cleanup()

    def test_czyszczenie_nazwy(self):
        self.assertEqual(S.czysc_nazwe("  Panel\x00 \x1b[31m  admina\n "), "Panel [31m admina")
        self.assertEqual(len(S.czysc_nazwe("x" * 500)), S.MAKS_NAZWA)
        # znaczniki zostają dosłownie — panel pokazuje je jako zwykły tekst
        self.assertEqual(S.czysc_nazwe("<img src=x>"), "<img src=x>")

    def test_nazwa_i_kolor_zapis_odczyt_reset(self):
        self.assertEqual(S.ustaw_wlasne("nazwy", "docker:a#1", "Sklep  testowy"), "Sklep testowy")
        self.assertEqual(S.ustaw_wlasne("kolory", "docker:a#1", "zielony"), "zielony")
        nazwy, kolory = S.ustawienia_wlasne()
        self.assertEqual((nazwy, kolory), ({"docker:a#1": "Sklep testowy"}, {"docker:a#1": "zielony"}))
        S.ustaw_wlasne("nazwy", "docker:a#1", "   ")
        S.ustaw_wlasne("kolory", "docker:a#1", "")
        self.assertEqual(S.ustawienia_wlasne(), ({}, {}))

    def test_tylko_kolory_z_palety(self):
        with self.assertRaises(ValueError):
            S.ustaw_wlasne("kolory", "docker:a#1", "#ff0000")

    def test_zly_klucz(self):
        with self.assertRaises(ValueError):
            S.ustaw_wlasne("nazwy", "zly\x01klucz", "x")
        with self.assertRaises(ValueError):
            S.ustaw_wlasne("nazwy", "", "x")
        with self.assertRaises(ValueError):
            S.ustaw_wlasne("nazwy", "k" * (S.MAKS_KLUCZ + 1), "x")

    def test_reczna_edycja_pliku_jest_filtrowana(self):
        with open(S.USTAWIENIA_PLIK, "w", encoding="utf-8") as f:
            f.write('{"nazwy": {"a": "ok", "b": "\\u0000"}, "kolory": {"a": "zielony", "b": "neon"}}')
        self.assertEqual(S.ustawienia_wlasne(), ({"a": "ok"}, {"a": "zielony"}))


class LancuchProcesow(unittest.TestCase):
    """Na żywo: proces-dziecko pod powłoką pod tym procesem testowym."""

    def setUp(self):
        self.proc = subprocess.Popen(["sh", "-c", "sleep 30; :"])
        self.dziecko = None
        for _ in range(50):
            dzieci = [int(p) for p in os.listdir("/proc") if p.isdigit() and S.rodzic(int(p)) == self.proc.pid]
            if dzieci:
                self.dziecko = dzieci[0]
                break
            time.sleep(0.05)

    def tearDown(self):
        self.proc.kill()
        self.proc.wait()
        if self.dziecko:
            try:
                os.kill(self.dziecko, 9)
            except OSError:
                pass

    def test_agent_przodek_i_powloka(self):
        self.assertIsNotNone(self.dziecko)
        moj = S.comm(os.getpid())
        wynik = S.lancuch(self.dziecko, {moj: "Agent Testowy"})
        self.assertEqual(wynik["agent"], "Agent Testowy")
        self.assertTrue(wynik["powloka"])
        self.assertIn(self.proc.pid, wynik["pidy"])

    def test_agent_nad_nieznanym_programem_posrednim(self):
        # agent (ten proces) → „devreload” (nieznany program) → sleep
        katalog = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, katalog)
        wrapper = os.path.join(katalog, "devreload")
        shutil.copy("/usr/bin/bash", wrapper)
        p = subprocess.Popen([wrapper, "-c", "sleep 30; :"])
        self.addCleanup(lambda: (p.kill(), p.wait()))
        dziecko = None
        for _ in range(50):
            dzieci = [int(x) for x in os.listdir("/proc") if x.isdigit() and S.rodzic(int(x)) == p.pid]
            if dzieci:
                dziecko = dzieci[0]
                break
            time.sleep(0.05)
        self.assertIsNotNone(dziecko)
        self.addCleanup(lambda: os.kill(dziecko, 9))
        wynik = S.lancuch(dziecko, {S.comm(os.getpid()): "Agent Testowy"})
        self.assertEqual(wynik["agent"], "Agent Testowy")

    def test_agent_samego_procesu(self):
        self.assertEqual(S.agent_procesu(self.dziecko, {"sleep": "Śpioch"}), "Śpioch")
        self.assertEqual(S.agent_procesu(self.dziecko, {}), "")


if __name__ == "__main__":
    unittest.main()
