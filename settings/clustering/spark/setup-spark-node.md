# Spark 4.2.0: WSL 기반 Standalone 노드 설치

스크립트는 각 노드에서 개별적으로 실행하며, 다음 작업을 수행한다.

1. Conda 환경 spark를 생성하거나 활성화한다.
2. Spark 4.2.0을 사용자의 홈 디렉터리 아래에 설치한다.
3. Standalone Master와 Worker 데몬 실행에 필요한 `spark-env.sh`를 생성한다.
4. 생성된 설정과 실행 명령을 요약해 출력한다.

현재 범위는 설치와 Standalone 데몬 설정까지다.

Spark job 제출용 기본값 파일은 필수 설치 단계에서 제외하며, 문서 하단 Appendix A에서 선택 사항으로 설명한다.

## 버전 및 경로

- Spark 버전: 4.2.0
- Spark 배포판: `spark-4.2.0-bin-hadoop3.tgz`
- Conda 환경: `spark`
- Python: 3.12
- Java: OpenJDK 17
- 압축 파일: `~/spark-4.2.0-bin-hadoop3.tgz`
- Spark 설치 경로: `~/spark-4.2.0-bin-hadoop3`
- Spark 설정 경로: `~/spark-4.2.0-bin-hadoop3/conf`

## 입력값

local IP는 사용자에게 입력받지 않는다. 스크립트가 `hostname -I | awk '{print $1}'`를 실행해 현재 노드의 첫 번째 IP를 자동으로 설정한다. `hostname -I`가 여러 주소를 반환하는 환경에서는 첫 번째 주소를 사용한다.

스크립트는 다음 값을 순서대로 입력받는다.

1. master host IP
   - Spark Master가 실행되는 노드의 IPv4 주소
2. master port
   - Spark Standalone Master 통신 포트
   - 기본값 예시: `7077`
3. master web UI port
   - Spark Master Web UI 포트
   - 기본값 예시: `8080`
4. worker cores
   - 현재 Worker가 Spark 애플리케이션에 제공할 CPU 코어 수
   - 사용자 입력의 worker code는 `SPARK_WORKER_CORES`에 맞춰 worker cores로 해석한다.
5. worker memory
   - 현재 Worker가 Spark 애플리케이션에 제공할 메모리
   - 예: 6g, 8192m
6. daemon memory
   - Spark Master와 Worker 데몬에 할당할 메모리
   - 예: 256m, 1g

### 입력값 검증

- IP는 올바른 IPv4 형식이어야 한다.
- 포트는 1부터 65535 사이의 정수여야 한다.
- Worker core 수는 양의 정수여야 한다.
- 메모리 값은 숫자와 단위가 포함된 Spark 메모리 형식이어야 한다.
- 필수 입력이 비어 있으면 다시 입력받는다.

master host IP, Master 포트, Master Web UI 포트는 클러스터 전체에서 동일하게 사용한다.

## Conda 환경 생성 및 활성화

스크립트는 먼저 Conda 실행 파일을 찾는다.

spark 환경이 없으면 다음 명령으로 생성한다.

~~~bash
conda create -y -n spark python=3.12 openjdk=17
~~~

spark 환경이 이미 있으면 새로 생성하지 않고 활성화한다.

~~~bash
conda activate spark
~~~

활성화 후 다음을 확인한다.

- 현재 활성 환경이 spark인지 확인한다.
- `$CONDA_PREFIX/bin/python`이 존재하는지 확인한다.
- `$CONDA_PREFIX/bin/java`가 존재하는지 확인한다.
- Python이 3.12인지 확인한다.
- Java가 OpenJDK 17인지 확인한다.

Python 또는 Java 버전이 요구사항과 다르면 설치를 중단하고 다음 명령을 출력한다. 사용자는 기존 `spark` 환경을 제거한 뒤 스크립트를 다시 실행해야 한다.

~~~bash
conda deactivate
conda env remove -y -n spark
bash setup-spark-node.sh
~~~

스크립트 내부에서 활성화한 환경은 해당 스크립트 프로세스에 적용된다.

## Spark 다운로드 및 설치

Conda 환경을 활성화한 뒤 홈 디렉터리에서 작업을 수행한다.

~~~bash
cd ~

curl --fail --location --retry 3 \
  --output ./spark-4.2.0-bin-hadoop3.tgz \
  "https://dlcdn.apache.org/spark/spark-4.2.0/spark-4.2.0-bin-hadoop3.tgz"

tar -xzf ./spark-4.2.0-bin-hadoop3.tgz -C ~
~~~

기존 `~/spark-4.2.0-bin-hadoop3` 설치 경로가 있으면 해당 디렉터리를 삭제한 뒤 처음부터 다시 설치한다.

`~/spark-4.2.0-bin-hadoop3.tgz`가 이미 존재하면 기존 압축 파일을 재사용한다. 압축 파일이 없을 때만 다운로드한다.

압축 해제 후 다음 실행 파일이 존재하는지 확인한다.

- `~/spark-4.2.0-bin-hadoop3/bin/spark-submit`
- `~/spark-4.2.0-bin-hadoop3/sbin/start-master.sh`
- `~/spark-4.2.0-bin-hadoop3/sbin/start-worker.sh`

## Spark Standalone 설정

Spark 설치 후 `~/spark-4.2.0-bin-hadoop3/conf` 아래에 `spark-env.sh`를 생성한다.

`spark-env.sh`는 Standalone Master와 Worker 데몬 실행에 사용하는 노드 단위 환경 변수 파일이다.
`SPARK_LOCAL_IP`에는 입력받지 않고 `hostname -I`로 자동 감지한 현재 노드의 IP를 사용한다.

~~~bash
export PYSPARK_PYTHON=$CONDA_PREFIX/bin/python
export PYSPARK_DRIVER_PYTHON="$PYSPARK_PYTHON"

export SPARK_LOCAL_IP=<local-ip>
export SPARK_MASTER_HOST=<master-host-ip>
export SPARK_MASTER_PORT=<master-port>
export SPARK_MASTER_WEBUI_PORT=<master-webui-port>

export SPARK_WORKER_CORES=<worker-cores>
export SPARK_WORKER_MEMORY=<worker-memory>
export SPARK_DAEMON_MEMORY=<daemon-memory>
~~~

생성 후 `spark-env.sh`는 실행 가능하도록 설정한다.

~~~bash
cd ~/spark-4.2.0-bin-hadoop3
chmod +x ./conf/spark-env.sh
~~~

`SPARK_LOCAL_IP`은 노드별 값이다. Master 주소와 Master 포트 관련 값은 클러스터 전체에서 동일하게 사용한다.

## 스크립트 실행 흐름

1. WSL 환경인지 확인한다.
2. Conda spark 환경을 생성하거나 활성화한다.
3. Python, Java 및 필수 명령을 확인한다.
4. local IP를 자동 감지하고, Master와 Worker 설정값을 입력받는다.
5. 홈 디렉터리로 이동한다.
6. Spark 압축 파일을 홈 디렉터리에 다운로드하고 압축을 해제한다.
7. `spark-env.sh`를 생성하고 실행 권한을 부여한다.
8. 생성된 파일과 설정값을 검증한다.
9. `bin/`, `sbin/` 디렉토리 내부의 스크립트를 실행 가능하게 설정한다.
10. Spark Master와 Worker 시작 명령을 출력한다.

## 최종 출력

스크립트 종료 전 다음 정보를 출력한다.

- 활성 Conda 환경
- Spark 버전
- 현재 노드의 local IP
- Master 주소와 포트
- Worker cores, Worker memory, daemon memory
- Master 시작 명령
- Worker 시작 명령

## Spark Standalone 실행 흐름

스크립트는 설치와 설정 생성 후 Master와 Worker 시작 명령을 출력한다. 데몬은 사용자가 각 노드에서 직접 시작한다.

Master 노드에서 실행할 명령:

~~~bash
cd ~/spark-4.2.0-bin-hadoop3
conda activate spark
./sbin/start-master.sh
~~~

각 Worker 노드에서 실행할 명령:

~~~bash
cd ~/spark-4.2.0-bin-hadoop3
conda activate spark
./sbin/start-worker.sh \
  "spark://<master-host-ip>:<master-port>"
~~~

Spark Standalone 데몬을 시작하는 데 `spark-defaults.conf`는 필요하지 않다. Job 제출용 기본 설정이 필요한 경우에는 Appendix A의 파일을 별도로 생성한다.

## 추후 확정할 항목

- Master 노드에서만 Master를 시작할지 여부
- Worker Web UI 포트와 Worker 통신 포트를 입력받을지 여부
- Spark 관련 값을 `~/.bashrc`에도 저장할지 여부

## Appendix A. spark-defaults.conf

### A.1 역할

spark-defaults.conf는 Spark Master와 Worker 데몬을 시작하기 위한 필수 파일이 아니다.

이 파일은 spark-submit 또는 spark-shell로 Spark job을 제출할 때 자동으로 읽는 애플리케이션 기본 설정 파일이다. 따라서, Spark job 제출 시 반복해서 사용할 기본값을 저장하려는 경우에만 선택적으로 생성한다.

### A.2 client 모드의 Driver 주소

client 모드에서는 Driver가 spark-submit을 실행한 노드에서 실행된다. Executor와 Standalone Master가 Driver에 접속해야 하므로, spark.driver.host에 제출 노드의 local IP를 명시한다.

spark.driver.host는 Standalone Master나 Worker 데몬을 띄우는 설정이 아니라, client 모드 Spark job의 Driver 통신에 사용하는 설정이다.

### A.3 선택적 기본 설정 예시

~~~text
spark.master                     spark://<master-host-ip>:<master-port>
spark.submit.deployMode          client
spark.driver.host                <local-ip>
spark.driver.bindAddress         0.0.0.0
spark.driver.port                7090
spark.driver.blockManager.port   7091
spark.driver.memory              1g
spark.executor.memory            12g
spark.executor.cores             10
spark.cores.max                  18
spark.dynamicAllocation.enabled  false
spark.default.parallelism        4
spark.sql.shuffle.partitions     4
spark.sql.session.timeZone       Asia/Seoul
~~~

### A.4 리소스 설정 검토 규칙

- spark.executor.memory는 Worker memory보다 작거나 같아야 한다.
- spark.executor.cores는 SPARK_WORKER_CORES보다 작거나 같아야 한다.
- spark.cores.max는 클러스터 전체 Worker core 수를 초과하지 않는 범위에서 설정한다.
- Worker memory가 6g인데 spark.executor.memory가 12g인 조합은 그대로 사용할 수 없다.
- Driver 포트를 고정하면 방화벽 설정은 쉬워지지만, 한 노드에서 여러 애플리케이션을 동시에 실행할 때 포트 충돌이 발생할 수 있다.
