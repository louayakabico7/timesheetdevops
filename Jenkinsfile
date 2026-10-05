pipeline {
    agent any
    tools {
        maven 'M3'
    }
    environment {
        IMAGE_NAME = 'alae123alae/timesheet'
        IMAGE_TAG = "${BUILD_NUMBER}"
        EMAIL_TO = 'sabeel.agtn@gmail.com'
        KUBECONFIG = '/var/jenkins_home/.kube/config'
    }
    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        stage('Secret Scan (Gitleaks)') {
            steps {
                // Post-commit gate: same scan as the local pre-commit hook, but bypass-proof.
                // Runs as a pinned container; mounts only jenkins_home (not the Docker socket).
                sh '''
                    VOL=$(docker inspect jenkins --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Name}}{{end}}{{end}}')
                    docker run --rm --mount type=volume,src=$VOL,dst=/var/jenkins_home -w "$WORKSPACE" zricethezav/gitleaks:v8.30.1 git --redact --no-banner
                '''
            }
        }
        stage('SAST (Semgrep)') {
            steps {
                // Static analysis on the checked-out source; fails the build on findings
                sh '''
                    VOL=$(docker inspect jenkins --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Name}}{{end}}{{end}}')
                    docker run --rm --mount type=volume,src=$VOL,dst=/var/jenkins_home -w "$WORKSPACE" semgrep/semgrep:1.178.0 semgrep scan --config=p/ci --config=p/security-audit --quiet --error --exclude zap-report.html --exclude target .
                '''
            }
        }
        stage('Clean') {
            steps {
                sh 'mvn clean'
                // Stamp a unique version per build: maven-releases rejects re-deploying version 1.0 (HTTP 400)
                sh 'mvn versions:set -DnewVersion=1.0.${BUILD_NUMBER} -DgenerateBackupPoms=false'
            }
        }
        stage('Compile') {
            steps {
                sh 'mvn compile'
            }
        }
        stage('Test') {
            steps {
                sh 'mvn test'
            }
        }
        stage('OWASP Dependency-Check') {
            steps {
                // Requires NVD API key (https://nvd.nist.gov/developers/request-an-api-key)
                // stored as Jenkins secret-text credential 'nvc-api-key'; key passed via env var
                // (dependency-check 13.x reads nvdApiKeyEnvironmentVariable; -Dnvd.api.key was removed)
                catchError(buildResult: 'UNSTABLE', stageResult: 'FAILURE') {
                    withCredentials([string(credentialsId: 'nvc-api-key', variable: 'NVD_API_KEY')]) {
                        sh 'mvn org.owasp:dependency-check-maven:13.0.0:check -Dformat=HTML -DfailBuildOnCVSS=11 -DnvdApiKeyEnvironmentVariable=NVD_API_KEY'
                    }
                }
            }
        }
        stage('SonarQube') {
            steps {
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    sh 'mvn org.sonarsource.scanner.maven:sonar-maven-plugin:3.9.1.2184:sonar -Dsonar.host.url=http://sonarqube:9000 -Dsonar.login=$SONAR_TOKEN'
                }
            }
        }
        stage('Package') {
            steps {
                sh 'mvn package -DskipTests'
            }
        }
        stage('Publish Artifact to Nexus') {
            steps {
                // pom.xml points to localhost:8081, but inside Jenkins container use nexus hostname
                // Requires Jenkins credential nexus-creds (Nexus admin user)
                catchError(buildResult: 'UNSTABLE', stageResult: 'FAILURE') {
                    withCredentials([usernamePassword(credentialsId: 'nexus-creds', usernameVariable: 'NEXUS_USER', passwordVariable: 'NEXUS_PASS')]) {
                        sh '''
                            cat > nexus-settings.xml <<EOF
<settings>
  <servers>
    <server>
      <id>deploymentRepo</id>
      <username>$NEXUS_USER</username>
      <password>$NEXUS_PASS</password>
    </server>
  </servers>
</settings>
EOF
                            mvn -s nexus-settings.xml deploy -DskipTests -DaltDeploymentRepository=deploymentRepo::default::http://nexus:8081/repository/maven-releases/
                        '''
                    }
                }
            }
        }
        stage('Docker Build') {
            steps {
                sh "docker build -t ${IMAGE_NAME}:${IMAGE_TAG} ."
            }
        }
        stage('Docker Push') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'dockerhub-creds',
                    usernameVariable: 'DOCKER_USER',
                    passwordVariable: 'DOCKER_PASS'
                )]) {
                    sh '''
                        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                        docker push ${IMAGE_NAME}:${IMAGE_TAG}
                    '''
                }
            }
        }
        stage('Kubernetes Deploy') {
            steps {
                // Manifests in k8s/ use namespace chap4-khadijabenjaafar-4nids3 and image khadijabenjaafar/timesheet:1.0
                // Update image to the one just built, then apply:
                sh '''
                    kubectl create namespace chap4-khadijabenjaafar-4nids3 --dry-run=client -o yaml | kubectl apply -f -
                    kubectl apply -f k8s/
                    kubectl -n chap4-khadijabenjaafar-4nids3 set image deployment/timesheet-dep timesheet=${IMAGE_NAME}:${IMAGE_TAG} || true
                '''
            }
        }
        stage('Kubernetes Verification') {
            steps {
                sh 'kubectl -n chap4-khadijabenjaafar-4nids3 get pods'
                sh 'kubectl -n chap4-khadijabenjaafar-4nids3 get deployments'
                sh 'kubectl -n chap4-khadijabenjaafar-4nids3 rollout status deployment/timesheet-dep --timeout=120s || true'
            }
        }
        stage('DAST (ZAP)') {
            steps {
                // Black-box scan of the RUNNING app (SAST/SCA can only see the code).
                // 1. port-forward the k8s Service onto localhost of this container
                // 2. ZAP container shares our network namespace (--network container:jenkins)
                //    so it reaches http://localhost:30007 ...
                // -I: only FAIL-level findings break the build, warnings are reported
                sh '''
                    set -e
                    VOL=$(docker inspect jenkins --format '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Name}}{{end}}{{end}}')
                    pkill -f 'port-forward svc/timesheet-service' 2>/dev/null || true
                    # make sure this build's rollout finished and the service has a ready endpoint
                    kubectl -n chap4-khadijabenjaafar-4nids3 rollout status deployment/timesheet-dep --timeout=120s || true
                    k=0
                    until [ -n "$(kubectl -n chap4-khadijabenjaafar-4nids3 get endpoints timesheet-service -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)" ]; do
                        k=$((k+1))
                        if [ $k -ge 30 ]; then echo 'service has no ready endpoint'; exit 1; fi
                        sleep 2
                    done
                    # port-forward; restart it if it dies (it can attach to a pod that is being replaced)
                    PF=0
                    start_pf() {
                        kubectl -n chap4-khadijabenjaafar-4nids3 port-forward svc/timesheet-service 30007:8080 >> /tmp/zap-pf.log 2>&1 &
                        PF=$!
                    }
                    start_pf
                    trap 'kill $PF 2>/dev/null || true' EXIT
                    i=0
                    until curl -s -o /dev/null -m 2 http://localhost:30007/timesheet-devops/user/retrieve-all-users; do
                        if ! kill -0 $PF 2>/dev/null; then echo 'port-forward died, restarting...'; start_pf; fi
                        i=$((i+1))
                        if [ $i -ge 45 ]; then echo 'app not reachable through port-forward'; cat /tmp/zap-pf.log; exit 1; fi
                        sleep 2
                    done
                    docker run --rm --network container:jenkins --mount type=volume,src=$VOL,dst=/zap/wrk zaproxy/zap-stable:2.17.0 \
                        zap-baseline.py -t http://localhost:30007/timesheet-devops/user/retrieve-all-users \
                        -r zap-report.html -m 1 -I -s
                    mv -f /var/jenkins_home/zap-report.html "$WORKSPACE/zap-report.html"
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'zap-report.html', allowEmptyArchive: true
                }
            }
        }
        stage('Acceptance') {
            steps {
                // automated acceptance: business behaviour of the DEPLOYED staging app
                sh 'sh acceptance/acceptance-tests.sh chap4-khadijabenjaafar-4nids3 timesheet-service 30009'
                // human sign-off: nothing reaches production without it
                timeout(time: 15, unit: 'MINUTES') {
                    input message: "Acceptance sign-off: promote build #${BUILD_NUMBER} to production?", ok: 'Accept for production'
                }
            }
        }
        stage('Production') {
            steps {
                // promote the SAME image tag to an isolated production namespace.
                // Manifests are re-namespaced on the fly (single source of truth, no duplicate yaml).
                sh '''
                    set -e
                    kubectl create namespace chap4-khadijabenjaafar-prod --dry-run=client -o yaml | kubectl apply -f -
                    for f in k8s/*.yaml; do
                        sed -e 's/chap4-khadijabenjaafar-4nids3/chap4-khadijabenjaafar-prod/g' \
                            -e 's/nodePort: 30007/nodePort: 30008/' "$f" | kubectl apply -f -
                    done
                    kubectl -n chap4-khadijabenjaafar-prod set image deployment/timesheet-dep timesheet=${IMAGE_NAME}:${IMAGE_TAG}
                    if ! kubectl -n chap4-khadijabenjaafar-prod rollout status deployment/timesheet-dep --timeout=240s; then
                        echo 'production rollout FAILED - rolling back to the previous release'
                        kubectl -n chap4-khadijabenjaafar-prod rollout undo deployment/timesheet-dep || true
                        exit 1
                    fi
                    kubectl -n chap4-khadijabenjaafar-prod get pods
                '''
                // production must behave exactly like what acceptance signed off
                sh 'sh acceptance/acceptance-tests.sh chap4-khadijabenjaafar-prod timesheet-service 30010'
            }
        }
        stage('Operation') {
            steps {
                // operational readiness of the RUNNING system:
                // monitoring stack must answer and every pod in staging + production must be ready
                sh '''
                    set -e
                    echo '--- Prometheus ---'
                    if curl -sf -m 10 http://prometheus:9090/-/ready > /dev/null; then echo 'prometheus: ready'; else echo 'prometheus NOT ready'; exit 1; fi
                    echo '--- Grafana ---'
                    if curl -sf -m 10 http://grafana:3000/api/health; then echo ''; else echo 'grafana NOT healthy'; exit 1; fi
                    echo '--- Prometheus scrape targets UP ---'
                    TARGETS=$(curl -sf -m 10 http://prometheus:9090/api/v1/targets) || { echo 'cannot query prometheus targets'; exit 1; }
                    UP=$(echo "$TARGETS" | grep -o '"health":"up"' | wc -l)
                    DOWN=$(echo "$TARGETS" | grep -o '"health":"down"' | wc -l)
                    echo "targets: $UP up, $DOWN down"
                    if [ "$UP" -lt 1 ]; then echo 'no scrape target is up'; exit 1; fi
                    echo '--- Kubernetes workloads (staging + production) ---'
                    for ns in chap4-khadijabenjaafar-4nids3 chap4-khadijabenjaafar-prod; do
                        kubectl -n $ns get pods
                        bad=$(kubectl -n $ns get pods --no-headers | awk '$2 != "1/1" || $3 != "Running"' | wc -l)
                        if [ "$bad" -ne 0 ]; then echo "namespace $ns has $bad pod(s) not ready"; exit 1; fi
                    done
                    echo 'operation checks passed'
                '''
            }
        }
    }
    post {
        success {
            emailext(
                to: "${EMAIL_TO}",
                subject: "SUCCESS: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                body: "Pipeline SUCCESS: ${env.BUILD_URL}"
            )
        }
        failure {
            emailext(
                to: "${EMAIL_TO}",
                subject: "FAILURE: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                body: "Pipeline FAILED: ${env.BUILD_URL}"
            )
        }
        aborted {
            emailext(
                to: "${EMAIL_TO}",
                subject: "ABORTED: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                body: "Pipeline ABORTED: ${env.BUILD_URL}"
            )
        }
        unstable {
            emailext(
                to: "${EMAIL_TO}",
                subject: "UNSTABLE: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                body: "Pipeline UNSTABLE: ${env.BUILD_URL}"
            )
        }
        always {
            echo 'Post Actions completed.'
            // versions:set modified pom.xml; restore it so the next checkout stays clean
            sh 'git checkout -- pom.xml || true'
        }
    }
}
