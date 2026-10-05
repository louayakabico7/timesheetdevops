package tn.esprit.spring.repository;

import org.springframework.data.jpa.repository.JpaRepository;

import tn.esprit.spring.entities.AuditLog;

public interface AuditLogRepository extends JpaRepository<AuditLog, Long> {
}
