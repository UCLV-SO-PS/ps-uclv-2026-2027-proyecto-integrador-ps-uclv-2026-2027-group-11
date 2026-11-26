"""Pruebas reales de TCP, procesos y señales. Requieren el puerto 6666 libre."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import re
import signal
import socket
import subprocess
import tempfile
import time
import unittest

RAIZ = Path(__file__).resolve().parents[1]
EPISODIOS = [
    ("S01E01", "The Hedge Knight", "9.2", 45120),
    ("S01E02", "Hard Salt Beef", "8.8", 38900),
    ("S01E03", "The Squire", "9.5", 52400),
    ("S01E04", "Seven", "9.1", 41200),
    ("S01E05", "In the Name of the Mother", "9.7", 68300),
    ("S01E06", "The Morrow", "9.4", 49800),
]


def recibir(conexion):
    """Lee hasta que el servidor cierre su extremo de la conexión."""
    partes = []
    while True:
        datos = conexion.recv(512)
        if not datos:
            return b"".join(partes).decode("utf-8")
        partes.append(datos)


def consultar(codigo):
    """Realiza una consulta con un cliente TCP independiente del programa en C."""
    with socket.create_connection(("127.0.0.1", 6666), timeout=8) as conexion:
        conexion.sendall(codigo.encode("ascii"))
        conexion.shutdown(socket.SHUT_WR)
        return recibir(conexion)


def respuesta_esperada(episodio):
    """Construye la respuesta esperada a partir de los datos de la orientación."""
    codigo, titulo, puntuacion, votos = episodio
    return (f"Codigo: {codigo}\nEpisodio: {titulo}\n"
            f"Puntuacion IMDb: {puntuacion}\nVotos: {votos}\n")


def hijos_del_proceso(padre):
    """Consulta PPid y estado en /proc, sin depender del archivo opcional children."""
    hijos = {}
    for directorio in Path("/proc").iterdir():
        if not directorio.name.isdecimal():
            continue
        try:
            lineas = (directorio / "status").read_text().splitlines()
            campos = dict(linea.split(":", 1) for linea in lineas if ":" in linea)
            if campos.get("PPid", "").strip() == str(padre):
                hijos[directorio.name] = campos["State"].strip().split()[0]
        except (OSError, KeyError):
            # Un proceso puede terminar mientras se recorre /proc.
            continue
    return hijos


class PruebasServidor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporal = tempfile.TemporaryDirectory()
        cls.ruta_registro = Path(cls.temporal.name) / "servidor.log"
        cls.registro = cls.ruta_registro.open("w")
        cls.proceso = subprocess.Popen(
            [str(RAIZ / "server")], cwd=RAIZ, stdout=cls.registro,
            stderr=cls.registro, start_new_session=True)
        for _ in range(100):
            if cls.proceso.poll() is not None:
                mensaje = cls.ruta_registro.read_text()
                cls.registro.close()
                cls.temporal.cleanup()
                raise RuntimeError("No se pudo iniciar el servidor de pruebas: " + mensaje)
            if "Servidor TCP en puerto" in cls.ruta_registro.read_text():
                break
            time.sleep(0.02)
        else:
            cls.proceso.kill()
            cls.proceso.wait()
            cls.registro.close()
            cls.temporal.cleanup()
            raise RuntimeError("El servidor no terminó de iniciarse.")

    @classmethod
    def tearDownClass(cls):
        cls.proceso.terminate()
        try:
            cls.proceso.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(cls.proceso.pid, signal.SIGKILL)
            cls.proceso.wait()
        cls.registro.close()
        cls.temporal.cleanup()

    def ejecutar_cliente(self, *argumentos):
        """Ejecuta el cliente real y devuelve su resultado."""
        return subprocess.run([str(RAIZ / "client"), *argumentos], cwd=RAIZ,
                              capture_output=True, text=True, timeout=8)

    def test_01_seis_episodios_exactos_por_tcp(self):
        for episodio in EPISODIOS:
            with self.subTest(codigo=episodio[0]):
                self.assertEqual(consultar(episodio[0]), respuesta_esperada(episodio))

    def test_02_cliente_real(self):
        for episodio in EPISODIOS:
            with self.subTest(codigo=episodio[0]):
                resultado = self.ejecutar_cliente(episodio[0], "127.0.0.1")
                self.assertEqual(resultado.returncode, 0, resultado.stderr)
                self.assertEqual(resultado.stdout, respuesta_esperada(episodio))

    def test_03_episodio_inexistente(self):
        self.assertEqual(consultar("S01E99"), "ERROR: episodio no encontrado.\n")
        resultado = self.ejecutar_cliente("S01E99")
        self.assertNotEqual(resultado.returncode, 0)
        self.assertIn("ERROR:", resultado.stdout)

    def test_04_codigo_fragmentado(self):
        with socket.create_connection(("127.0.0.1", 6666), timeout=8) as conexion:
            conexion.sendall(b"S0")
            conexion.settimeout(0.1)
            with self.assertRaises(socket.timeout):
                conexion.recv(512)
            conexion.settimeout(8)
            conexion.sendall(b"1E05")
            conexion.shutdown(socket.SHUT_WR)
            self.assertEqual(recibir(conexion), respuesta_esperada(EPISODIOS[4]))

    def test_05_solicitud_incompleta(self):
        self.assertIn("codigo incompleto", consultar("S01"))

    def test_06_codigo_con_terminador_interno(self):
        self.assertIn("ERROR:", consultar("S0\x00E01"))

    def test_07_sesenta_clientes_concurrentes(self):
        peticiones = EPISODIOS * 10
        with ThreadPoolExecutor(max_workers=20) as grupo:
            resultados = list(grupo.map(lambda e: consultar(e[0]), peticiones))
        self.assertEqual(resultados, [respuesta_esperada(e) for e in peticiones])

    @unittest.skipUnless(Path("/proc/self/stat").exists(), "Requiere /proc de Linux")
    def test_08_procesos_distintos_ip_y_sigint(self):
        conexiones = [socket.create_connection(("127.0.0.1", 6666), timeout=8)
                      for _ in range(3)]
        try:
            for _ in range(100):
                hijos = hijos_del_proceso(self.proceso.pid)
                registros = self.ruta_registro.read_text()
                if len(hijos) >= 3 and all(
                    estado != "Z" and f"PID hijo: {hijo}\n" in registros
                    for hijo, estado in hijos.items()
                ):
                    break
                time.sleep(0.01)
            self.assertGreaterEqual(len(hijos), 3)
            for hijo in hijos:
                estado = Path(f"/proc/{hijo}/status").read_text()
                self.assertIn(f"PPid:\t{self.proceso.pid}\n", estado)
            for hijo in hijos:
                self.assertIn(f"IP cliente: 127.0.0.1 | PID hijo: {hijo}", registros)
            # Envía SIGINT al padre y sus hijos, como hace una terminal con Ctrl+C.
            os.killpg(self.proceso.pid, signal.SIGINT)
            self.assertIsNone(self.proceso.poll())
            for conexion in conexiones:
                conexion.sendall(b"S01E01")
                conexion.shutdown(socket.SHUT_WR)
                self.assertEqual(recibir(conexion), respuesta_esperada(EPISODIOS[0]))
        finally:
            for conexion in conexiones:
                conexion.close()

    def test_09_cliente_lento_no_bloquea_a_otro(self):
        with socket.create_connection(("127.0.0.1", 6666), timeout=8) as lento:
            lento.sendall(b"S01")
            inicio = time.monotonic()
            self.assertEqual(consultar("S01E06"), respuesta_esperada(EPISODIOS[5]))
            self.assertLess(time.monotonic() - inicio, 2)
            self.assertIn("tiempo permitido", recibir(lento))

    @unittest.skipUnless(Path("/proc/self/stat").exists(), "Requiere /proc de Linux")
    def test_10_sin_zombis_ni_fugas_de_descriptores(self):
        for _ in range(30):
            consultar("S01E01")
        for _ in range(100):
            if not hijos_del_proceso(self.proceso.pid):
                break
            time.sleep(0.01)
        self.assertEqual(hijos_del_proceso(self.proceso.pid), {})
        # stdin, stdout, stderr y socket de escucha; ningún descriptor por cliente queda abierto.
        self.assertEqual(len(list(Path(f"/proc/{self.proceso.pid}/fd").iterdir())), 4)

    def test_11_argumentos_invalidos_del_cliente(self):
        for argumentos in [(), ("S01",), ("s01e01",), ("S01E01X",),
                           ("S01E01", "no-es-ip"), ("S01E01", "127.0.0.1", "extra")]:
            with self.subTest(argumentos=argumentos):
                self.assertNotEqual(self.ejecutar_cliente(*argumentos).returncode, 0)

    def test_12_puerto_ocupado_se_informa_sin_interferir(self):
        resultado = subprocess.run([str(RAIZ / "server")], cwd=RAIZ,
                                   capture_output=True, text=True, timeout=8)
        self.assertNotEqual(resultado.returncode, 0)
        self.assertIn("puerto 6666", resultado.stderr)
        self.assertEqual(consultar("S01E02"), respuesta_esperada(EPISODIOS[1]))

    def test_13_desconexion_abrupta(self):
        for _ in range(10):
            conexion = socket.create_connection(("127.0.0.1", 6666), timeout=8)
            conexion.sendall(b"S01E01")
            conexion.close()
        self.assertEqual(consultar("S01E03"), respuesta_esperada(EPISODIOS[2]))


if __name__ == "__main__":
    unittest.main(verbosity=2)

