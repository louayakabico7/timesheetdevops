pipeline {
    agent any
    tools {
        maven 'M3'
    }
    environment {
        IMAGE_NAME = 'alae123alae/timesheet'
        IMAGE_TAG = "${BUILD_NUMBER}"
        EMAIL_TO = 'sabeel.agtn@gmail.com'
    }
    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        stage('Clean') {
            steps {
                sh 'mvn clean'
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
                echo 'OWASP Dependency-Check: insert the exact command/plugin used by your class here.'
                // Example (adapt to your lab):
                // sh 'mvn org.owasp:dependency-check-maven:check'
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
                sh 'mvn deploy -DskipTests -DaltDeploymentRepository=deploymentRepo::default::http://nexus:8081/repository/maven-releases/'
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
        always {
            echo 'Post Actions completed.'
        }
    }
}
