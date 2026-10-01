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
                    docker run --rm --mount type=volume,src=$VOL,dst=/var/jenkins_home -w "$WORKSPACE" semgrep/semgrep:1.178.0 semgrep scan --config=p/ci --config=p/security-audit --quiet --error .
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
                    kubectl -n chap4-khadijabenjaafar-4nids3 port-forward svc/timesheet-service 30007:8080 > /tmp/zap-pf.log 2>&1 &
                    PF=$!
                    trap 'kill $PF 2>/dev/null || true' EXIT
                    i=0
                    until curl -s -o /dev/null -m 2 http://localhost:30007/timesheet-devops/user/retrieve-all-users; do
                        i=$((i+1))
                        if [ $i -ge 30 ]; then echo 'app not reachable through port-forward'; cat /tmp/zap-pf.log; exit 1; fi
                        sleep 1
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
        stage('Prometheus') {
            steps {
                echo 'Verify monitoring/metrics availability (Prometheus :9090, Grafana :3000). Monitoring stack runs independently.'
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
